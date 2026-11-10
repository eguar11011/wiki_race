defmodule Player.Fetcher do
  @moduledoc """
  Worker: descarga una página, extrae sus enlaces y responde según el tipo de trabajo.

    * `:forward`: reclama en ETS los artículos nuevos y busca enlaces a destinos.
    * `:probe`: devuelve los enlaces del objetivo.
    * `:candidate`: indica si la página enlaza al objetivo.

  Los errores HTTP son resultados normales. Una excepción hace caer el proceso;
  OTP la registra y la carrera repone el worker.
  """

  use GenServer, restart: :temporary, shutdown: :brutal_kill

  alias Player.{Links, Stats}

  def start_link(context), do: GenServer.start_link(__MODULE__, context)

  def fetch(pid, job), do: GenServer.cast(pid, {:fetch, job})

  @impl true
  def init(context), do: {:ok, context}

  @impl true
  def handle_cast({:fetch, job}, context) do
    send(context.race, {:result, self(), job, run(job, context)})
    # Hibernar compacta el proceso y libera las referencias al HTML recién parseado.
    {:noreply, context, :hibernate}
  end

  defp run(job, context) do
    with {:ok, body} <- download(job.url, context),
         {:ok, links} <- Links.extract(body, job.url) do
      conclude(job, links, context)
    else
      :error -> {:error, :unparseable}
      {:error, reason} -> {:error, reason}
    end
  end

  # Como el verificador: sin reintentos y siguiendo redirecciones. Solo cambia el timeout.
  defp download(url, context) do
    started = System.monotonic_time(:microsecond)
    result = Req.get(url, [retry: false, receive_timeout: context.timeout_ms] ++ context.req_options)
    Stats.add(context.stats, :download_us, System.monotonic_time(:microsecond) - started)

    case result do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        Stats.add(context.stats, :pages)
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp conclude(%{kind: :probe}, links, _context), do: {:ok, links}

  defp conclude(%{kind: :candidate}, links, context),
    do: {:ok, List.keymember?(links, context.target_canon, 0)}

  defp conclude(job, links, context) do
    jobs = Enum.flat_map(links, &claim(&1, job, context))
    {:ok, jobs, suffixes(links, context)}
  end

  # Restos de camino conocidos a partir de los enlaces de la página, los más cortos primero.
  defp suffixes(links, context) do
    links
    |> Enum.flat_map(fn {canon, _url} -> :ets.lookup(context.goals, canon) end)
    |> Enum.map(fn {_canon, suffix} -> suffix end)
    |> Enum.sort_by(&length/1)
  end

  defp claim({canon, url}, parent, context) do
    cond do
      canon == context.target_canon or not Links.article?(canon, context.prefix) ->
        []

      not room?(context) ->
        # Solo registra que un límite dejó la exploración incompleta (causa :resource_limit).
        :atomics.put(context.limits, 3, 1)
        []

      :ets.insert_new(context.seen, {canon, url, parent.canon, parent.depth + 1}) ->
        :atomics.add(context.limits, 1, 1)

        [%{canon: canon, url: url, depth: parent.depth + 1, kind: :forward}]

      true ->
        Stats.add(context.stats, :duplicates)
        []
    end
  end

  defp room?(%{limits: limits, max_discovered: max}),
    do: :atomics.get(limits, 1) < max and :atomics.get(limits, 2) == 0
end
