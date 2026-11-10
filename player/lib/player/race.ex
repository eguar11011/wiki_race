defmodule Player.Race do
  @moduledoc """
  Una carrera. Es el pid que devuelve `start/2`.

  Reparte trabajo entre los Fetchers, aplica sus resultados y reporta una sola
  vez. Posee las tablas ETS de la carrera y un `DynamicSupervisor` enlazado con los
  Fetchers: si el harness mata este proceso, desaparece todo.

  La búsqueda principal es una BFS asíncrona (`Player.Frontier`). Con
  `strategy: :reverse` (por defecto) se añade la reciprocidad verificada de
  `Player.Reverse`: no es una BFS bidireccional, solo confirma predecesores del
  objetivo entre sus propios enlaces. `strategy: :bfs` la desactiva.

  La tabla `goals` guarda artículos desde los que se conoce el resto del camino.
  Al principio solo contiene el objetivo; la reciprocidad añade los predecesores
  confirmados, y un enlace a cualquiera de ellos es un encuentro.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Player.{Fetcher, Frontier, Links, Reverse, Route, Stats, StatusTable}
  alias WikiRace.{Harness, Status}

  @defaults %{
    strategy: :reverse,
    concurrency: 16,
    timeout_ms: 5_000,
    max_discovered: 250_000,
    memory_limit: 400 * 1024 * 1024,
    memory_check_ms: 250,
    # El harness solo espera 5 s a las verificaciones pendientes al terminar.
    deadline_ms: 114_000,
    max_replacements: 64,
    reverse: [],
    req_options: []
  }

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({start_url, target_url, opts}) do
    config = Map.merge(@defaults, Map.new(opts))
    start_canon = Links.canonical(start_url)
    target_canon = Links.canonical(target_url)

    case Links.book_prefix(start_canon) do
      {:ok, prefix} ->
        reverse? = reverse?(config.strategy)
        seen = :ets.new(:race_seen, [:set, :public, write_concurrency: true])
        goals = :ets.new(:race_goals, [:set, :public, read_concurrency: true])
        :ets.insert(seen, {start_canon, start_url, nil, 0})
        :ets.insert(goals, {target_canon, [target_url]})
        {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
        :ok = StatusTable.register(self(), Status.new(frontier_size: 1))
        start_job = %{canon: start_canon, url: start_url, depth: 0, kind: :forward}

        context = %{
          race: self(),
          seen: seen,
          goals: goals,
          # Control de recursos, separado de las estadísticas: 1 = descubiertos, 2 = memoria excedida.
          limits: :atomics.new(2, []),
          stats: Stats.new(),
          prefix: prefix,
          target_canon: target_canon,
          max_discovered: config.max_discovered,
          timeout_ms: config.timeout_ms,
          req_options: config.req_options
        }

        state = %{
          config: config,
          context: context,
          supervisor: supervisor,
          start_url: start_url,
          target_url: target_url,
          frontier: Frontier.push(Frontier.new(), [start_job]),
          reverse: if(reverse?, do: Reverse.new(target_canon, target_url, config.reverse)),
          workers: %{},
          idle: [],
          active: %{},
          pages: 0,
          replacements: 0,
          memory_max: 0,
          status: Status.new(frontier_size: 1),
          done: false,
          started_at: System.monotonic_time(:millisecond)
        }

        {:ok, state, {:continue, :start}}

      :error ->
        {:stop, :invalid_start_url}
    end
  end

  defp reverse?(:reverse), do: true
  defp reverse?(:bfs), do: false

  @impl true
  def handle_continue(:start, state) do
    Process.send_after(self(), :check_memory, state.config.memory_check_ms)
    Process.send_after(self(), :deadline, state.config.deadline_ms)
    state = Enum.reduce(1..state.config.concurrency, state, fn _n, acc -> add_worker(acc) end)
    {:noreply, step(state)}
  end

  @impl true
  def handle_info({:result, _pid, _job, _result}, %{done: true} = state), do: {:noreply, state}

  def handle_info({:result, pid, job, result}, state) do
    state = %{state | active: Map.delete(state.active, pid), idle: [pid | state.idle]}
    {:noreply, state |> apply_result(job, result) |> step()}
  end

  # Un Fetcher que lanza una excepción muere (y OTP registra el error): se repone.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{workers: workers} = state)
      when is_map_key(workers, pid) do
    Stats.add(state.context.stats, :errors)

    state = %{
      state
      | workers: Map.delete(workers, pid),
        idle: List.delete(state.idle, pid),
        active: Map.delete(state.active, pid)
    }

    {:noreply, state |> replace_worker() |> step()}
  end

  def handle_info(:check_memory, %{done: false} = state) do
    total = :erlang.memory(:total)
    :atomics.put(state.context.limits, 2, if(total > state.config.memory_limit, do: 1, else: 0))
    Process.send_after(self(), :check_memory, state.config.memory_check_ms)
    {:noreply, %{state | memory_max: max(state.memory_max, total)}}
  end

  def handle_info(:deadline, %{done: false} = state), do: {:noreply, finish(state, :exhausted, [])}
  def handle_info(_message, state), do: {:noreply, state}

  defp apply_result(state, job, {:error, _reason}) do
    Stats.add(state.context.stats, :errors)
    %{state | pages: state.pages + forward(job), reverse: Reverse.failed(state.reverse, job.kind)}
  end

  defp apply_result(state, %{kind: :forward} = job, {:ok, jobs, hits}) do
    state |> visited(job) |> push(jobs) |> try_routes(job.canon, hits)
  end

  defp apply_result(state, %{kind: :probe} = job, {:ok, links}) do
    seen? = &:ets.member(state.context.seen, &1)
    state = visited(state, job)
    %{state | reverse: Reverse.probed(state.reverse, links, state.context.prefix, seen?)}
  end

  defp apply_result(state, %{kind: :candidate} = job, {:ok, confirmed?}) do
    Stats.add(state.context.stats, :candidates_checked)
    state = visited(state, job)
    state = %{state | reverse: Reverse.checked(state.reverse, confirmed?)}
    if confirmed?, do: confirm(state, job), else: state
  end

  # Un candidato confirmado pasa a ser un destino. Si ya se alcanzó desde el origen, hay camino.
  defp confirm(state, job) do
    Stats.add(state.context.stats, :candidates_confirmed)
    :ets.insert(state.context.goals, {job.canon, [job.url, state.target_url]})

    if :ets.member(state.context.seen, job.canon),
      do: try_routes(state, job.canon, [[state.target_url]]),
      else: state
  end

  # `suffixes`: restos de camino conocidos desde los enlaces de `page`, los más cortos primero.
  defp try_routes(state, _page, []), do: state

  defp try_routes(state, page, [suffix | rest]) do
    if length(suffix) > 1, do: Stats.add(state.context.stats, :encounters)

    with {:ok, path} <- Route.build(state.context.seen, page, suffix),
         :ok <- Route.validate(path, state.start_url, state.target_url) do
      finish(state, :found, path)
    else
      {:error, reason} ->
        Logger.warning("Camino descartado: #{inspect(reason)}")
        try_routes(state, page, rest)
    end
  end

  defp visited(state, job) do
    status = %{state.status | current_url: job.url, visited_count: state.status.visited_count + 1}
    %{state | status: status, pages: state.pages + forward(job)}
  end

  defp forward(%{kind: :forward}), do: 1
  defp forward(_job), do: 0

  defp push(state, jobs), do: %{state | frontier: Frontier.push(state.frontier, jobs)}

  defp step(state), do: state |> dispatch() |> maybe_exhausted() |> publish()

  defp dispatch(%{done: false, idle: [worker | rest]} = state) do
    case next_job(state) do
      {nil, state} ->
        state

      {job, state} ->
        Fetcher.fetch(worker, job)
        dispatch(%{state | idle: rest, active: Map.put(state.active, worker, job)})
    end
  end

  defp dispatch(state), do: state

  defp next_job(%{reverse: nil} = state), do: pop_frontier(state)

  defp next_job(state) do
    frontier_empty? = Frontier.size(state.frontier) == 0

    case Reverse.next(state.reverse, state.pages, frontier_empty?) do
      {nil, reverse} -> pop_frontier(%{state | reverse: reverse})
      {job, reverse} -> {job, %{state | reverse: reverse}}
    end
  end

  defp pop_frontier(state) do
    case Frontier.pop(state.frontier) do
      {job, frontier} -> {job, %{state | frontier: frontier}}
      :empty -> {nil, state}
    end
  end

  # Tras repartir, nada en curso significa que no queda trabajo (o que no quedan workers).
  defp maybe_exhausted(%{done: false, active: active} = state) when map_size(active) == 0,
    do: finish(state, :exhausted, [])

  defp maybe_exhausted(state), do: state

  defp publish(%{done: true} = state), do: state

  defp publish(state) do
    status = %{state.status | frontier_size: Frontier.size(state.frontier)}
    StatusTable.publish(self(), status)
    %{state | status: status}
  end

  defp add_worker(state) do
    {:ok, pid} = DynamicSupervisor.start_child(state.supervisor, {Fetcher, state.context})
    %{state | workers: Map.put(state.workers, pid, Process.monitor(pid)), idle: [pid | state.idle]}
  end

  defp replace_worker(%{replacements: n, config: %{max_replacements: max}} = state) when n < max,
    do: add_worker(%{state | replacements: n + 1})

  defp replace_worker(state), do: state

  defp finish(state, outcome, path) do
    record_path(state, path)
    status = %{state.status | state: outcome, path: path, frontier_size: 0}
    # `status/1` debe mostrar el camino antes de que llegue el reporte.
    StatusTable.publish(self(), status)
    report(outcome, path)

    Enum.each(state.workers, fn {pid, ref} ->
      Process.demonitor(ref, [:flush])
      DynamicSupervisor.terminate_child(state.supervisor, pid)
    end)

    :ets.delete_all_objects(state.context.seen)

    state = %{
      state
      | done: true,
        status: status,
        workers: %{},
        idle: [],
        active: %{},
        frontier: Frontier.new()
    }

    StatusTable.publish_stats(self(), summary(state))
    state
  end

  defp record_path(_state, []), do: :ok

  defp record_path(state, path) do
    Stats.put(state.context.stats, :first_path_ms, System.monotonic_time(:millisecond) - state.started_at)
    Stats.put(state.context.stats, :path_length, length(path))
  end

  defp report(:found, path), do: Harness.report(path)
  defp report(:exhausted, _path), do: Harness.report_exhausted()

  defp summary(state) do
    state.context.stats
    |> Stats.snapshot()
    |> Map.merge(%{
      strategy: state.config.strategy,
      discovered: :atomics.get(state.context.limits, 1),
      memory_max: state.memory_max
    })
  end
end
