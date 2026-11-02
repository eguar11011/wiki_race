defmodule Player.DFS do
  @moduledoc """
  Búsqueda en profundidad, basada en tu implementación original de `MiDFS`.

  Una lista actúa como pila: exploramos sus primeros elementos antes del resto.
  Acepta un mapa o una función de vecinos, igual que `Player.BFS`.
  """

  @doc """
  Devuelve `{:ok, camino}`, `:sin_camino` o `{:error, razon}`.

  `max_visitados` limita las expansiones, por defecto 100.
  DFS encuentra un camino, pero no garantiza el de menor número de saltos.
  """
  def buscar(grafo_o_vecinos, inicio, objetivo, opts \\ [])

  def buscar(grafo, inicio, objetivo, opts) when is_map(grafo) do
    vecinos_de = fn nodo -> {:ok, Map.get(grafo, nodo, [])} end
    buscar(vecinos_de, inicio, objetivo, opts)
  end

  def buscar(vecinos_de, inicio, objetivo, opts) when is_function(vecinos_de, 1) do
    limite = Keyword.get(opts, :max_visitados, 100)

    unless is_integer(limite) and limite >= 0 do
      raise ArgumentError, "max_visitados debe ser un entero mayor o igual a cero"
    end

    pila = [{inicio, [inicio]}]
    visitados = MapSet.new()
    explorar(vecinos_de, pila, visitados, objetivo, 0, limite)
  end

  def ejemplo do
    buscar(Player.Ejemplos.grafo(), "A", "F")
  end

  defp explorar(_vecinos_de, [], _visitados, _objetivo, _explorados, _limite) do
    :sin_camino
  end

  defp explorar(vecinos_de, [{actual, camino} | resto], visitados, objetivo, explorados, limite) do
    cond do
      actual == objetivo ->
        {:ok, Enum.reverse(camino)}

      MapSet.member?(visitados, actual) ->
        explorar(vecinos_de, resto, visitados, objetivo, explorados, limite)

      explorados >= limite ->
        {:error, :limite_alcanzado}

      true ->
        with {:ok, vecinos} <- vecinos_de.(actual) do
          nuevos_visitados = MapSet.put(visitados, actual)

          # PREGUNTA: ¿por qué [vecino | camino] y un reverse al encontrar la meta?
          nuevos = Enum.map(vecinos, fn vecino -> {vecino, [vecino | camino]} end)

          # PREGUNTA: ¿qué cambiaría si usamos resto ++ nuevos?
          nueva_pila = nuevos ++ resto

          explorar(vecinos_de, nueva_pila, nuevos_visitados, objetivo, explorados + 1, limite)
        end
    end
  end
end

defmodule MiDFS do
  @moduledoc "Compatibilidad con las llamadas de tu primer ejemplo."
  @spec buscar((any() -> any()) | map(), any(), any()) :: any()
  defdelegate buscar(grafo, inicio, objetivo), to: Player.DFS
  defdelegate ejemplo(), to: Player.DFS
end
