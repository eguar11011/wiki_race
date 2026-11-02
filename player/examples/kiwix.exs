# Desde player/: mix run examples/kiwix.exs bfs URL_INICIO URL_OBJETIVO 100
args = System.argv()

case args do
  [algoritmo, inicio, objetivo | opciones] when algoritmo in ["bfs", "dfs"] ->
    limite =
      case opciones do
        [] ->
          100

        [valor] ->
          case Integer.parse(valor) do
            {numero, ""} when numero >= 0 -> numero
            _ -> raise ArgumentError, "El límite debe ser un entero mayor o igual a cero"
          end

        _ ->
          raise ArgumentError, "Usa: bfs|dfs URL_INICIO URL_OBJETIVO [max_visitados]"
      end

    estrategia = if algoritmo == "bfs", do: :bfs, else: :dfs
    IO.puts("Buscando con #{algoritmo}; máximo #{limite} páginas por expandir...")

    resultado = Player.Ejemplos.kiwix(estrategia, inicio, objetivo, max_visitados: limite)
    IO.inspect(resultado, label: "Resultado", limit: :infinity, printable_limit: :infinity)

  _ ->
    raise ArgumentError,
          "Usa: mix run examples/kiwix.exs bfs|dfs URL_INICIO URL_OBJETIVO [max_visitados]"
end
