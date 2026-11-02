defmodule Player.BusquedasTest do
  use ExUnit.Case, async: true

  test "BFS elige el camino corto y DFS sigue primero la rama B" do
    assert {:ok, ["A", "C", "F"]} = Player.BFS.ejemplo()
    assert {:ok, ["A", "B", "D", "E", "F"]} = Player.DFS.ejemplo()
    assert MiDFS.ejemplo() == Player.DFS.ejemplo()
  end

  for algoritmo <- [Player.BFS, Player.DFS] do
    describe "#{inspect(algoritmo)}" do
      test "termina sin camino aun cuando hay ciclos" do
        grafo = %{"A" => ["B", "B"], "B" => ["A"]}
        assert :sin_camino = unquote(algoritmo).buscar(grafo, "A", "Z")
      end

      test "inicio igual a objetivo no consulta vecinos" do
        vecinos_de = fn _ -> flunk("No debe expandir la meta") end
        assert {:ok, ["A"]} = unquote(algoritmo).buscar(vecinos_de, "A", "A", max_visitados: 0)
      end

      test "cada nodo se expande una sola vez aunque tenga varios predecesores" do
        grafo = %{"A" => ["B", "C"], "B" => ["D"], "C" => ["D"], "D" => ["A"]}
        contador = self()

        vecinos_de = fn nodo ->
          send(contador, {:expandido, nodo})
          {:ok, Map.fetch!(grafo, nodo)}
        end

        assert :sin_camino = unquote(algoritmo).buscar(vecinos_de, "A", "Z")
        for nodo <- Map.keys(grafo), do: assert_receive({:expandido, ^nodo})
        refute_receive {:expandido, _}
      end

      test "el límite no se confunde con demostrar que no hay camino" do
        grafo = %{"A" => ["B"], "B" => ["C"]}

        assert {:error, :limite_alcanzado} =
                 unquote(algoritmo).buscar(grafo, "A", "C", max_visitados: 1)

        assert {:ok, ["A", "B", "C"]} =
                 unquote(algoritmo).buscar(grafo, "A", "C", max_visitados: 2)
      end

      test "los errores al obtener vecinos se devuelven al llamador" do
        vecinos_de = fn "A" -> {:error, {:http, 404}} end
        assert {:error, {:http, 404}} = unquote(algoritmo).buscar(vecinos_de, "A", "B")
      end

      test "rechaza un límite negativo" do
        assert_raise ArgumentError, fn ->
          unquote(algoritmo).buscar(%{}, "A", "B", max_visitados: -1)
        end
      end
    end
  end

  test "Kiwix rechaza inicio y objetivo en distintos servidores o libros antes de descargar" do
    inicio = "http://localhost:8080/content/wiki/A"

    for objetivo <- [
          "http://otro-servidor:8080/content/wiki/B",
          "http://localhost:8080/content/otro-libro/B"
        ] do
      assert {:error, :distinto_servidor_o_libro} = Player.Ejemplos.kiwix(:bfs, inicio, objetivo)
    end
  end
end
