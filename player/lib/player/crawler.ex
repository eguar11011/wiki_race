defmodule Player.Crawler do
  @moduledoc """
  Punto de entrada de la competencia: inicia una búsqueda BFS supervisada y
  permite consultar su progreso sin esperar las descargas de Kiwix.
  """

  @behaviour WikiRace.Crawler

  @impl WikiRace.Crawler
  def start(start_url, target_url), do: start(start_url, target_url, [])

  @doc "Inicia BFS con un máximo de descargas simultáneas (8 por defecto)."
  def start(start_url, target_url, opts) do
    concurrencia =
      Keyword.get(opts, :max_concurrency, Application.get_env(:player, :max_concurrency, 8))

    with {:ok, inicio} <- Player.Wikipedia.normalizar_url(start_url),
         {:ok, objetivo} <- Player.Wikipedia.normalizar_url(target_url),
         :ok <- validar_destino(inicio, objetivo),
         :ok <- validar_concurrencia(concurrencia) do
      DynamicSupervisor.start_child(
        Player.CrawlerSupervisor,
        {Player.Coordinator, {inicio, objetivo, concurrencia}}
      )
    end
  end

  @impl WikiRace.Crawler
  def status(pid), do: GenServer.call(pid, :status, 200)

  defp validar_concurrencia(n) when is_integer(n) and n > 0, do: :ok
  defp validar_concurrencia(_), do: {:error, :max_concurrency_invalida}

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
