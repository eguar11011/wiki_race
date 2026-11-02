defmodule Player.BFS do
  @moduledoc """
  Búsqueda en anchura: una cola FIFO explora primero los caminos más cortos.

  Acepta un mapa de adyacencia o una función que obtiene los vecinos de un nodo.
  Cada arista cuenta como un salto; no usamos pesos ni heurísticas todavía.
  """

  @doc """
  Devuelve `{:ok, camino}`, `:sin_camino` o `{:error, razon}`.

  `max_visitados` limita las expansiones (consultas de vecinos), por defecto 100.
  Alcanzar ese límite no significa que no exista un camino.
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

    cola = :queue.from_list([{inicio, [inicio]}])
    visitados = MapSet.new([inicio])
    explorar(vecinos_de, cola, visitados, objetivo, 0, limite)
  end

  def ejemplo do
    buscar(Player.Ejemplos.grafo(), "A", "F")
  end

  defp explorar(vecinos_de, cola, visitados, objetivo, explorados, limite) do
    case :queue.out(cola) do
      {:empty, _cola} ->
        :sin_camino

      {{:value, {actual, camino}}, resto} ->
        cond do
          actual == objetivo ->
            {:ok, Enum.reverse(camino)}

          explorados >= limite ->
            {:error, :limite_alcanzado}

          true ->
            with {:ok, vecinos} <- vecinos_de.(actual) do
              # PREGUNTA: ¿por qué marcar al ENCOLAR evita duplicar pendientes?
              {nueva_cola, nuevos_visitados} =
                Enum.reduce(vecinos, {resto, visitados}, fn vecino, {pendientes, vistos} ->
                  if MapSet.member?(vistos, vecino) do
                    {pendientes, vistos}
                  else
                    entrada = {vecino, [vecino | camino]}
                    {:queue.in(entrada, pendientes), MapSet.put(vistos, vecino)}
                  end
                end)

              explorar(vecinos_de, nueva_cola, nuevos_visitados, objetivo, explorados + 1, limite)
            end
        end
    end
  end
end
