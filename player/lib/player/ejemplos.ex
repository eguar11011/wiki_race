defmodule Player.Ejemplos do
  @moduledoc "Ejemplos de práctica, independientes de la carrera y del coordinador OTP."

  @doc "Grafo dirigido: incluye un ciclo D → A y dos caminos de A a F."
  def grafo do
    %{
      "A" => ["B", "C"],
      "B" => ["D"],
      "C" => ["F"],
      "D" => ["A", "E"],
      "E" => ["F"],
      "F" => []
    }
  end

  @doc "Ejecuta una búsqueda secuencial en un mismo libro de Kiwix con URLs completas."
  def kiwix(algoritmo, inicio_url, objetivo_url, opts \\ []) when algoritmo in [:bfs, :dfs] do
    with {:ok, inicio} <- Player.Wikipedia.normalizar_url(inicio_url),
         {:ok, objetivo} <- Player.Wikipedia.normalizar_url(objetivo_url),
         :ok <- mismo_libro(inicio, objetivo) do
      modulo = if algoritmo == :bfs, do: Player.BFS, else: Player.DFS
      modulo.buscar(&Player.Wikipedia.vecinos/1, inicio, objetivo, opts)
    end
  end

  defp mismo_libro(inicio, objetivo) do
    origen = URI.parse(inicio)
    destino = URI.parse(objetivo)

    mismo_origen =
      {origen.scheme, origen.host, origen.port} == {destino.scheme, destino.host, destino.port}

    libro_origen = origen.path |> String.split("/") |> Enum.take(3)
    libro_destino = destino.path |> String.split("/") |> Enum.take(3)

    if mismo_origen and libro_origen == libro_destino do
      :ok
    else
      {:error, :distinto_servidor_o_libro}
    end
  end
end
