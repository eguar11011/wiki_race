defmodule Player.Crawler do
  @moduledoc """
  Punto de entrada de la competencia: BFS concurrente con exploradores aleatorios.

  Por defecto permite 32 descargas simultáneas: reserva ocho cupos para el BFS
  principal y mantiene 24 exploradores. Cada explorador recorre diez enlaces
  reales antes de iniciar un BFS local limitado a 32 artículos descubiertos.
  Al encontrar una ruta la reporta inmediatamente y el BFS intenta acortarla.

  La plataforma utiliza `start/2` y `status/1`. La configuración no depende de
  Docker; `start/3` permite ajustar los presupuestos en las pruebas.
  """

  @behaviour WikiRace.Crawler

  @impl WikiRace.Crawler
  def start(start_url, target_url), do: start(start_url, target_url, [])

  @doc """
  Inicia una búsqueda supervisada sin esperar las descargas.

  Opciones: `:max_concurrency`, `:explorer_percent`, `:jump_hops`,
  `:explorer_budget` y `:random_seed`. También se admiten las variables
  `PLAYER_MAX_CONCURRENCY`, `PLAYER_EXPLORER_PERCENT`, `PLAYER_JUMP_HOPS`,
  `PLAYER_EXPLORER_BUDGET` y `PLAYER_RANDOM_SEED`. La semilla es opcional.
  """
  def start(start_url, target_url, opts) do
    concurrencia =
      opcion_entera(
        opts,
        :max_concurrency,
        "PLAYER_MAX_CONCURRENCY",
        Application.get_env(:player, :max_concurrency, 32)
      )

    with {:ok, inicio} <- Player.Wikipedia.normalizar_url(start_url),
         {:ok, objetivo} <- Player.Wikipedia.normalizar_url(target_url),
         :ok <- validar_destino(inicio, objetivo),
         :ok <- validar_concurrencia(concurrencia),
         {:ok, config} <- configurar_exploradores(concurrencia, opts) do
      DynamicSupervisor.start_child(
        Player.CrawlerSupervisor,
        {Player.ExplorerCoordinator, {inicio, objetivo, config}}
      )
    end
  end

  @impl WikiRace.Crawler
  def status(pid), do: GenServer.call(pid, :status, 200)

  defp validar_concurrencia(n) when is_integer(n) and n > 0, do: :ok
  defp validar_concurrencia(_), do: {:error, :max_concurrency_invalida}

  defp configurar_exploradores(concurrencia, opts) do
    porcentaje = opcion_entera(opts, :explorer_percent, "PLAYER_EXPLORER_PERCENT", 75)
    saltos = opcion_entera(opts, :jump_hops, "PLAYER_JUMP_HOPS", 10)
    presupuesto = opcion_entera(opts, :explorer_budget, "PLAYER_EXPLORER_BUDGET", 32)
    semilla = opcion_entera(opts, :random_seed, "PLAYER_RANDOM_SEED", nil)

    if is_integer(porcentaje) and porcentaje in 0..99 and
         is_integer(saltos) and saltos > 0 and
         is_integer(presupuesto) and presupuesto > 0 and
         (is_nil(semilla) or is_integer(semilla)) do
      {:ok,
       %{
         max_concurrency: concurrencia,
         explorer_count: div(concurrencia * porcentaje, 100),
         jump_hops: saltos,
         explorer_budget: presupuesto,
         random_seed: semilla
       }}
    else
      {:error, :configuracion_exploradores_invalida}
    end
  end

  defp opcion_entera(opts, clave, variable, defecto) do
    case Keyword.fetch(opts, clave) do
      {:ok, valor} ->
        valor

      :error ->
        case System.get_env(variable) do
          nil ->
            defecto

          valor ->
            case Integer.parse(valor) do
              {entero, ""} -> entero
              _ -> :invalido
            end
        end
    end
  end

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
