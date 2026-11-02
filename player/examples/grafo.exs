# Desde player/: mix run examples/grafo.exs
IO.inspect(Player.Ejemplos.grafo(), label: "Grafo")
IO.inspect(Player.BFS.ejemplo(), label: "BFS (2 saltos)")
IO.inspect(Player.DFS.ejemplo(), label: "DFS (4 saltos)")
