defmodule Player.Coordinator do
  @moduledoc """
  BFS concurrente por niveles, con un número limitado de descargas simultáneas.

  El GenServer conserva la cola FIFO, los padres de los artículos descubiertos
  y el estado público. Cada Task descarga una página y extrae sus enlaces.
  Los artículos descubiertos esperan en otra cola hasta terminar todas las
  descargas del nivel actual. Esta barrera conserva el camino mínimo de BFS
  aunque las respuestas HTTP lleguen en distinto orden.
  """

  use GenServer, restart: :temporary

  require Logger

  alias WikiRace.{Harness, Status}

  def start_link({inicio, objetivo, concurrencia}) do
    GenServer.start_link(__MODULE__, {inicio, objetivo, concurrencia})
  end

  @impl true
  def init({inicio, objetivo, concurrencia}) do
    # Un fallo HTTP no debe matar al coordinador. Los vínculos terminan los Tasks
    # si la plataforma mata este pid al terminar la carrera.
    Process.flag(:trap_exit, true)

    datos = %{
      objetivo: objetivo,
      cola: :queue.from_list([inicio]),
      siguiente_nivel: :queue.new(),
      padres: %{inicio => nil},
      tareas: %{},
      max_concurrency: concurrencia,
      estado: Status.new(frontier_size: 1)
    }

    send(self(), :buscar)
    {:ok, datos}
  end

  @impl true
  def handle_call(:status, _from, datos) do
    # El contrato tiene un solo current_url: mostramos uno de los trabajadores.
    actual =
      case Enum.take(datos.tareas, 1) do
        [{_ref, {_tarea, url}}] -> url
        [] -> datos.estado.current_url
      end

    {:reply, %{datos.estado | current_url: actual}, datos}
  end

  @impl true
  def handle_info(:buscar, datos), do: {:noreply, despachar(datos)}

  def handle_info({ref, resultado}, datos) when is_reference(ref) do
    case Map.pop(datos.tareas, ref) do
      {nil, _} ->
        # Puede llegar un resultado de un Task cancelado al encontrar la meta.
        {:noreply, datos}

      {{_tarea, actual}, tareas} ->
        Process.demonitor(ref, [:flush])
        estado = %{datos.estado | current_url: actual}
        datos = %{datos | tareas: tareas, estado: estado}

        case resultado do
          {:ok, vecinos} ->
            estado = %{datos.estado | visited_count: datos.estado.visited_count + 1}
            {:noreply, expandir(%{datos | estado: estado}, actual, vecinos) |> despachar()}

          {:error, razon} ->
            continuar_tras_error(datos, actual, razon)
        end
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, razon}, datos) do
    case Map.pop(datos.tareas, ref) do
      {nil, _} -> {:noreply, datos}
      {{_tarea, actual}, tareas} -> continuar_tras_error(%{datos | tareas: tareas}, actual, razon)
    end
  end

  # El resultado del Task se procesa con su referencia; su señal de salida no
  # cambia el estado. Un fallo se atiende mediante el monitor (:DOWN).
  def handle_info({:EXIT, _pid, _razon}, datos), do: {:noreply, datos}

  defp despachar(%{estado: %{state: estado}} = datos) when estado != :running, do: datos

  defp despachar(datos) when map_size(datos.tareas) >= datos.max_concurrency, do: datos

  defp despachar(datos) do
    case :queue.out(datos.cola) do
      {{:value, actual}, resto} ->
        tarea = Task.async(fn -> Player.Wikipedia.vecinos(actual) end)
        tareas = Map.put(datos.tareas, tarea.ref, {tarea, actual})

        estado = %{
          datos.estado
          | current_url: actual,
            frontier_size: datos.estado.frontier_size - 1
        }

        despachar(%{datos | cola: resto, tareas: tareas, estado: estado})

      {:empty, _} ->
        cond do
          map_size(datos.tareas) > 0 ->
            # Aunque haya cupos libres, todavía no se puede pasar de nivel.
            datos

          :queue.is_empty(datos.siguiente_nivel) ->
            Harness.report_exhausted()
            terminar(datos, :exhausted, [])

          true ->
            despachar(%{datos | cola: datos.siguiente_nivel, siguiente_nivel: :queue.new()})
        end
    end
  end

  defp expandir(datos, actual, vecinos) do
    if datos.objetivo in vecinos do
      padres = Map.put(datos.padres, datos.objetivo, actual)
      camino = reconstruir(padres, datos.objetivo, [])
      Harness.report(camino)
      terminar(datos, :found, camino)
    else
      {cola, padres, nuevos} =
        Enum.reduce(vecinos, {datos.siguiente_nivel, datos.padres, 0}, fn vecino,
                                                                          {cola, padres, nuevos} ->
          # Marcar al encolar evita duplicados y ciclos. Cada artículo conserva
          # el padre con el que se descubrió por primera vez: el camino más corto.
          if Map.has_key?(padres, vecino) do
            {cola, padres, nuevos}
          else
            {:queue.in(vecino, cola), Map.put(padres, vecino, actual), nuevos + 1}
          end
        end)

      estado = %{datos.estado | frontier_size: datos.estado.frontier_size + nuevos}
      %{datos | siguiente_nivel: cola, padres: padres, estado: estado}
    end
  end

  defp reconstruir(_padres, nil, camino), do: camino

  defp reconstruir(padres, actual, camino) do
    reconstruir(padres, Map.fetch!(padres, actual), [actual | camino])
  end

  defp continuar_tras_error(datos, actual, razon) do
    Logger.debug("Se omite #{actual}: #{inspect(razon)}")
    {:noreply, despachar(datos)}
  end

  defp terminar(datos, estado, camino) do
    # El pid permanece vivo para las consultas finales; la plataforma lo mata.
    # Cancelamos las otras descargas al encontrar un camino mínimo. No esperamos
    # sus respuestas: resultados y señales tardías se ignoran por referencia.
    Enum.each(datos.tareas, fn {ref, {tarea, _url}} ->
      Process.exit(tarea.pid, :kill)
      Process.demonitor(ref, [:flush])
    end)

    snapshot = %{datos.estado | state: estado, path: camino, frontier_size: 0}

    %{
      datos
      | cola: :queue.new(),
        siguiente_nivel: :queue.new(),
        padres: %{},
        tareas: %{},
        estado: snapshot
    }
  end
end
