defmodule Player.Crawler do
  @moduledoc """
  Punto de entrada de la competencia: BFS concurrente con exploradores aleatorios.

  La configuración es fija: permite 32 descargas simultáneas, reserva ocho cupos
  para el BFS principal y mantiene 24 exploradores. Cada explorador recorre diez enlaces
  reales antes de iniciar un BFS local limitado a 32 artículos descubiertos.
  Al encontrar una ruta la reporta inmediatamente y el BFS intenta acortarla.

  La plataforma utiliza `start/2` y `status/1`. Estos parámetros están definidos
  en el código y no dependen de opciones ni variables de entorno.
  """

  @behaviour WikiRace.Crawler

  @config %{
    max_concurrency: 32,
    bfs_concurrency: 8,
    explorer_count: 24,
    jump_hops: 10,
    explorer_budget: 32,
    random_seed: nil
  }

  @impl WikiRace.Crawler
  @doc "Inicia una búsqueda supervisada con la configuración fija, sin esperar las descargas."
  def start(start_url, target_url) do
    with {:ok, inicio} <- Player.Wikipedia.normalizar_url(start_url),
         {:ok, objetivo} <- Player.Wikipedia.normalizar_url(target_url),
         :ok <- validar_destino(inicio, objetivo) do
      DynamicSupervisor.start_child(
        Player.CrawlerSupervisor,
        {Player.ExplorerCoordinator, {inicio, objetivo, @config}}
      )
    end
  end

  @impl WikiRace.Crawler
  def status(pid), do: GenServer.call(pid, :status, 200)

  # El verificador de la plataforma exige al menos un enlace y no permite ciclos.
  defp validar_destino(inicio, inicio), do: {:error, :inicio_igual_al_objetivo}

  defp validar_destino(inicio, objetivo) do
    origen = URI.parse(inicio)
    destino = URI.parse(objetivo)

    mismo_servidor =
      {origen.scheme, origen.host, origen.port} == {destino.scheme, destino.host, destino.port}

    libro_origen = origen.path |> String.split("/") |> Enum.take(3)
    libro_destino = destino.path |> String.split("/") |> Enum.take(3)

    if mismo_servidor and libro_origen == libro_destino do
      :ok
    else
      {:error, :distinto_servidor_o_libro}
    end
  end
end
