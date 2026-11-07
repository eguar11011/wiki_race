# Desde player/: mix run examples/bfs_concurrente.exs URL_INICIO URL_OBJETIVO [trabajadores]
{inicio, objetivo, trabajadores} =
  case System.argv() do
    [inicio, objetivo] ->
      {inicio, objetivo, 8}

    [inicio, objetivo, valor] ->
      case Integer.parse(valor) do
        {numero, ""} when numero > 0 -> {inicio, objetivo, numero}
        _ -> raise ArgumentError, "Los trabajadores deben ser un entero mayor que cero"
      end

    _ ->
      raise ArgumentError,
            "Usa: mix run examples/bfs_concurrente.exs URL_INICIO URL_OBJETIVO [trabajadores]"
  end

case Player.Crawler.start(inicio, objetivo, max_concurrency: trabajadores) do
  {:ok, pid} ->
    IO.puts("BFS por niveles; máximo #{trabajadores} descargas simultáneas; límite 120 segundos")

    try do
      limite = System.monotonic_time(:millisecond) + 120_000

      esperar = fn esperar ->
        estado = Player.Crawler.status(pid)

        IO.puts(
          "#{estado.state}: descargadas=#{estado.visited_count}, pendientes=#{estado.frontier_size}"
        )

        cond do
          estado.state == :found ->
            {:ok, estado.path}

          estado.state == :exhausted ->
            :sin_camino

          System.monotonic_time(:millisecond) >= limite ->
            {:error, :tiempo_agotado}

          true ->
            Process.sleep(250)
            esperar.(esperar)
        end
      end

      IO.inspect(esperar.(esperar), label: "Resultado", limit: :infinity)
    after
      # Fuera de una carrera no hay harness que termine la búsqueda por nosotros.
      DynamicSupervisor.terminate_child(Player.CrawlerSupervisor, pid)
    end

  {:error, razon} ->
    raise "No se pudo iniciar BFS: #{inspect(razon)}"
end
