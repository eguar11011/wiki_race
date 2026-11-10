defmodule Player.Explorer do
  @moduledoc """
  Explorador sin descargas: sigue enlaces aleatorios y luego hace un BFS local.

  El coordinador entrega cada resultado y conserva el límite global de HTTP.
  El prefijo registra todas las aristas del salto; el BFS local conserva padres
  propios y excluye ese prefijo para producir caminos completos sin ciclos.
  Cada recorrido local descubre y solicita como máximo `budget` artículos.
  """

  defstruct phase: :jump,
            waiting: nil,
            root: nil,
            prefix: [],
            current: nil,
            remaining: 0,
            budget: 0,
            fetched_count: 0,
            frontier: {[], []},
            parents: %{},
            blocked: MapSet.new()

  @doc "Crea un recorrido desde un prefijo válido, incluido su artículo de partida."
  def new(prefix, jump_hops, budget)
      when is_list(prefix) and prefix != [] and is_integer(jump_hops) and jump_hops >= 0 and
             is_integer(budget) and budget >= 0 do
    explorer = %__MODULE__{
      prefix: prefix,
      current: List.last(prefix),
      remaining: jump_hops,
      budget: budget,
      blocked: MapSet.new(prefix)
    }

    if jump_hops == 0, do: land(explorer), else: explorer
  end

  @doc "Reubica el explorador utilizando un nuevo prefijo y presupuesto."
  def restart(prefix, jump_hops, budget), do: new(prefix, jump_hops, budget)

  @doc "Devuelve una solicitud pendiente; no descarga ni crea procesos."
  def next(%__MODULE__{phase: :done} = explorer), do: {:done, explorer}

  def next(%__MODULE__{waiting: url} = explorer) when not is_nil(url),
    do: {:request, url, explorer}

  def next(%__MODULE__{phase: :jump} = explorer) do
    {:request, explorer.current, %{explorer | waiting: explorer.current}}
  end

  def next(%__MODULE__{phase: :bfs} = explorer) do
    case :queue.out(explorer.frontier) do
      {{:value, url}, rest} ->
        {:request, url, %{explorer | waiting: url, current: url, frontier: rest}}

      {:empty, _} ->
        {:done, finish(explorer)}
    end
  end

  @doc "Consume solo el resultado del artículo solicitado y señala hallazgos completos."
  def receive_result(explorer, url, result, target)

  def receive_result(%__MODULE__{waiting: expected} = explorer, url, _result, _target)
      when expected != url or is_nil(expected),
      do: {:continue, explorer}

  def receive_result(%__MODULE__{phase: :jump} = explorer, _url, {:ok, links}, target) do
    explorer = %{explorer | waiting: nil}

    cond do
      target in links and not MapSet.member?(explorer.blocked, target) ->
        {:found, explorer.prefix ++ [target], finish(explorer)}

      true ->
        candidates = links |> Enum.uniq() |> Enum.reject(&MapSet.member?(explorer.blocked, &1))

        case candidates do
          [] ->
            {:done, finish(explorer)}

          _ ->
            chosen = Enum.at(candidates, :rand.uniform(length(candidates)) - 1)

            explorer = %{
              explorer
              | prefix: explorer.prefix ++ [chosen],
                current: chosen,
                remaining: explorer.remaining - 1,
                blocked: MapSet.put(explorer.blocked, chosen)
            }

            explorer = if explorer.remaining == 0, do: land(explorer), else: explorer
            continuation(explorer)
        end
    end
  end

  def receive_result(%__MODULE__{phase: :jump} = explorer, _url, {:error, _reason}, _target),
    do: {:done, finish(explorer)}

  def receive_result(%__MODULE__{phase: :bfs} = explorer, url, result, target) do
    explorer = %{explorer | waiting: nil, fetched_count: explorer.fetched_count + 1}

    case result do
      {:ok, links} ->
        if target in links and not MapSet.member?(explorer.blocked, target) do
          path = explorer.prefix ++ local_path(explorer.parents, url, []) ++ [target]
          {:found, path, finish(explorer)}
        else
          explorer
          |> enqueue(url, links)
          |> continuation()
        end

      {:error, _reason} ->
        continuation(explorer)
    end
  end

  @doc "Cuenta artículos pendientes; el artículo en curso no forma parte de la cola."
  def frontier_size(%__MODULE__{phase: :jump, waiting: nil}), do: 1
  def frontier_size(%__MODULE__{phase: :bfs, frontier: frontier}), do: :queue.len(frontier)
  def frontier_size(%__MODULE__{}), do: 0

  defp land(explorer) do
    explorer = %{explorer | phase: :bfs, root: explorer.current}

    if explorer.budget == 0 do
      finish(explorer)
    else
      %{
        explorer
        | frontier: :queue.from_list([explorer.root]),
          parents: %{explorer.root => nil}
      }
    end
  end

  defp enqueue(explorer, parent, links) do
    Enum.reduce_while(links, explorer, fn url, explorer ->
      cond do
        map_size(explorer.parents) >= explorer.budget ->
          {:halt, explorer}

        MapSet.member?(explorer.blocked, url) or Map.has_key?(explorer.parents, url) ->
          {:cont, explorer}

        true ->
          {:cont,
           %{
             explorer
             | frontier: :queue.in(url, explorer.frontier),
               parents: Map.put(explorer.parents, url, parent)
           }}
      end
    end)
  end

  # La raíz ya está al final del prefijo, por eso no se duplica al reconstruir.
  defp local_path(parents, url, path) do
    case Map.fetch!(parents, url) do
      nil -> path
      parent -> local_path(parents, parent, [url | path])
    end
  end

  defp continuation(%__MODULE__{phase: :done} = explorer), do: {:done, explorer}

  defp continuation(%__MODULE__{phase: :bfs} = explorer) do
    if :queue.is_empty(explorer.frontier),
      do: {:done, finish(explorer)},
      else: {:continue, explorer}
  end

  defp continuation(explorer), do: {:continue, explorer}

  defp finish(explorer),
    do: %{explorer | phase: :done, waiting: nil, frontier: :queue.new()}
end
