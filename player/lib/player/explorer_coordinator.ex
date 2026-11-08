defmodule Player.ExplorerCoordinator do
  @moduledoc """
  Mantiene un BFS por niveles y reserva parte de las descargas para exploradores.

  Cada explorador sigue enlaces al azar y hace un BFS local acotado. ETS guarda
  las aristas descargadas; los padres de cada búsqueda son independientes. Una
  URL pendiente tiene un solo Task y puede servir a varias búsquedas. Todos los
  Tasks están vinculados a este coordinador para terminar con el pid del contrato.
  """

  use GenServer, restart: :temporary

  alias Player.Explorer
  alias WikiRace.{Harness, Status}

  @work_per_turn 32
  @seed_pool_size 1_024
  @mission_pause_ms 100

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({inicio, objetivo, config}) do
    Process.flag(:trap_exit, true)
    semilla = config.random_seed || System.unique_integer([:positive, :monotonic])
    :rand.seed(:exsss, {semilla, semilla + 1, semilla + 2})

    exploradores =
      if config.explorer_count == 0,
        do: %{},
        else: Map.new(1..config.explorer_count, &{&1, nil})

    datos = %{
      objetivo: objetivo,
      config: config,
      main: %{
        cola: :queue.from_list([inicio]),
        siguiente: :queue.new(),
        padres: %{inicio => nil},
        esperando: MapSet.new(),
        expandidos: MapSet.new(),
        nivel: 0
      },
      exploradores: exploradores,
      disponibles: %{},
      turno: 0,
      semillas: [],
      cache: :ets.new(__MODULE__, [:set, :protected]),
      tareas: %{},
      pendientes: %{},
      estado: Status.new(frontier_size: 1),
      terminado: false,
      bombeo_programado: false,
      despertar: nil
    }

    send(self(), :bombear)
    {:ok, datos}
  end

  @impl true
  def handle_call(:status, _from, datos), do: {:reply, datos.estado, datos}

  @impl true
  def handle_info(:bombear, datos) do
    {:noreply, bombear(%{datos | bombeo_programado: false})}
  end

  def handle_info(:despertar, datos), do: {:noreply, bombear(%{datos | despertar: nil})}

  def handle_info({ref, resultado}, datos) when is_reference(ref) do
    case Map.pop(datos.tareas, ref) do
      {nil, _} ->
        {:noreply, datos}

      {trabajo, tareas} ->
        Process.demonitor(ref, [:flush])
        {:noreply, completar(%{datos | tareas: tareas}, trabajo, resultado) |> bombear()}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, razon}, datos) do
    case Map.pop(datos.tareas, ref) do
      {nil, _} ->
        {:noreply, datos}

      {trabajo, tareas} ->
        {:noreply, completar(%{datos | tareas: tareas}, trabajo, {:error, razon}) |> bombear()}
    end
  end

  def handle_info({:EXIT, _pid, _razon}, datos), do: {:noreply, datos}

  # El presupuesto por mensaje permite atender status incluso si muchos de los
  # siguientes artículos ya están en caché y no requieren esperar una descarga.
  defp bombear(datos), do: bombear(datos, @work_per_turn)
  defp bombear(%{terminado: true} = datos, _restantes), do: datos

  defp bombear(datos, 0) do
    datos = actualizar_snapshot(datos)

    if datos.bombeo_programado do
      datos
    else
      send(self(), :bombear)
      %{datos | bombeo_programado: true}
    end
  end

  defp bombear(datos, restantes) do
    datos = datos |> avanzar_nivel() |> preparar_exploradores()

    if datos.terminado do
      datos
    else
      case siguiente_trabajo(datos) do
        {:solicitar, consumidor, url, datos} ->
          datos |> solicitar(consumidor, url) |> bombear(restantes - 1)

        {:continuar, datos} ->
          bombear(datos, restantes - 1)

        :esperar ->
          datos |> actualizar_snapshot() |> programar_despertar()
      end
    end
  end

  defp avanzar_nivel(%{terminado: true} = datos), do: datos

  defp avanzar_nivel(datos) do
    main = datos.main

    cond do
      datos.estado.path != [] and main.nivel + 2 >= length(datos.estado.path) ->
        terminar(datos)

      not :queue.is_empty(main.cola) or MapSet.size(main.esperando) > 0 ->
        datos

      :queue.is_empty(main.siguiente) ->
        terminar(datos)

      true ->
        main = %{main | cola: main.siguiente, siguiente: :queue.new(), nivel: main.nivel + 1}
        avanzar_nivel(%{datos | main: main})
    end
  end

  defp preparar_exploradores(%{terminado: true} = datos), do: datos
  defp preparar_exploradores(%{estado: %{state: :found}} = datos), do: datos

  defp preparar_exploradores(datos) do
    ahora = System.monotonic_time(:millisecond)

    Enum.reduce(Enum.sort(Map.keys(datos.exploradores)), datos, fn id, datos ->
      explorador = datos.exploradores[id]

      cond do
        is_nil(explorador) and Map.get(datos.disponibles, id, ahora) <= ahora and
            not main_necesita_cupo?(datos) ->
          iniciar_mision(datos, id)

        not is_nil(explorador) and explorador.phase == :bfs and
          is_nil(explorador.waiting) and
            MapSet.member?(datos.main.expandidos, explorador.root) ->
          # Solo se reubica cuando el BFS ya expandió la raíz local, no por
          # haberla descubierto o por coincidir con otro nodo del explorador.
          prefijo = reconstruir(datos.main.padres, explorador.root)
          nuevo = Explorer.new(prefijo, datos.config.jump_hops, datos.config.explorer_budget)
          put_in(datos.exploradores[id], nuevo)

        true ->
          datos
      end
    end)
  end

  defp main_necesita_cupo?(datos) do
    not :queue.is_empty(datos.main.cola) and hay_cupo?(datos) and
      MapSet.size(datos.main.esperando) <
        datos.config.max_concurrency - datos.config.explorer_count
  end

  defp iniciar_mision(datos, id) do
    candidatas = Enum.reject(datos.semillas, &MapSet.member?(datos.main.expandidos, &1))
    libres = Enum.reject(candidatas, &Map.has_key?(datos.pendientes, &1))
    candidatas = if libres == [], do: candidatas, else: libres

    case candidatas do
      [] ->
        datos

      _ ->
        prefijo = reconstruir(datos.main.padres, Enum.random(candidatas))
        explorador = Explorer.new(prefijo, datos.config.jump_hops, datos.config.explorer_budget)
        put_in(datos.exploradores[id], explorador)
    end
  end

  defp siguiente_trabajo(datos) do
    cupos_main = datos.config.max_concurrency - datos.config.explorer_count
    cabeza = :queue.peek(datos.main.cola)

    cond do
      match?({:value, _}, cabeza) and reutilizable?(datos, elem(cabeza, 1)) ->
        tomar_main(datos)

      match?({:value, _}, cabeza) and hay_cupo?(datos) and
          MapSet.size(datos.main.esperando) < cupos_main ->
        tomar_main(datos)

      true ->
        case siguiente_explorador(datos) do
          :esperar ->
            # El BFS toma los cupos que los exploradores no necesitan. Cuando
            # se libera otro cupo, la cuota reservada vuelve a tener prioridad.
            if match?({:value, _}, cabeza) and hay_cupo?(datos),
              do: tomar_main(datos),
              else: :esperar

          trabajo ->
            trabajo
        end
    end
  end

  defp tomar_main(datos) do
    {{:value, url}, cola} = :queue.out(datos.main.cola)
    main = %{datos.main | cola: cola, esperando: MapSet.put(datos.main.esperando, url)}
    {:solicitar, :main, url, %{datos | main: main}}
  end

  defp siguiente_explorador(datos) do
    ids = Enum.sort(Map.keys(datos.exploradores))
    {antes, despues} = Enum.split_while(ids, &(&1 <= datos.turno))

    Enum.find_value(despues ++ antes, :esperar, fn id ->
      case datos.exploradores[id] do
        nil ->
          nil

        %{waiting: url} when not is_nil(url) ->
          nil

        explorador ->
          case Explorer.next(explorador) do
            {:done, _explorador} ->
              datos = put_in(datos.exploradores[id], nil)
              disponibles = Map.put(datos.disponibles, id, ahora() + @mission_pause_ms)
              {:continuar, %{datos | disponibles: disponibles, turno: id}}

            {:request, url, explorador} ->
              if reutilizable?(datos, url) or hay_cupo?(datos) do
                datos = put_in(datos.exploradores[id], explorador)
                {:solicitar, {:explorador, id}, url, %{datos | turno: id}}
              end
          end
      end
    end)
  end

  defp hay_cupo?(datos), do: map_size(datos.tareas) < datos.config.max_concurrency

  defp reutilizable?(datos, url),
    do: :ets.member(datos.cache, url) or Map.has_key?(datos.pendientes, url)

  defp solicitar(datos, consumidor, url) do
    case :ets.lookup(datos.cache, url) do
      [{^url, resultado}] ->
        entregar(datos, consumidor, url, resultado)

      [] ->
        case Map.fetch(datos.pendientes, url) do
          {:ok, ref} ->
            update_in(datos.tareas[ref].consumidores, &MapSet.put(&1, consumidor))

          :error ->
            tarea = Task.async(fn -> Player.Wikipedia.vecinos(url) end)

            trabajo = %{
              tarea: tarea,
              url: url,
              consumidores: MapSet.new([consumidor])
            }

            %{
              datos
              | tareas: Map.put(datos.tareas, tarea.ref, trabajo),
                pendientes: Map.put(datos.pendientes, url, tarea.ref)
            }
        end
    end
  end

  defp completar(datos, trabajo, resultado) do
    :ets.insert(datos.cache, {trabajo.url, resultado})
    visitados = datos.estado.visited_count + if(match?({:ok, _}, resultado), do: 1, else: 0)
    estado = %{datos.estado | current_url: trabajo.url, visited_count: visitados}
    datos = %{datos | pendientes: Map.delete(datos.pendientes, trabajo.url), estado: estado}

    # Primero el BFS: si ambos esperaban esta página, su ruta puede ser menor.
    trabajo.consumidores
    |> Enum.sort()
    |> Enum.reduce(datos, &entregar(&2, &1, trabajo.url, resultado))
  end

  defp entregar(%{terminado: true} = datos, _consumidor, _url, _resultado), do: datos

  defp entregar(datos, :main, url, resultado) do
    if MapSet.member?(datos.main.esperando, url) do
      main = %{
        datos.main
        | esperando: MapSet.delete(datos.main.esperando, url),
          expandidos: MapSet.put(datos.main.expandidos, url)
      }

      datos = %{datos | main: main}

      case resultado do
        {:ok, vecinos} -> expandir_main(datos, url, vecinos)
        {:error, _razon} -> datos
      end
    else
      datos
    end
  end

  defp entregar(datos, {:explorador, id}, url, resultado) do
    case datos.exploradores[id] do
      nil ->
        datos

      explorador ->
        case Explorer.receive_result(explorador, url, resultado, datos.objetivo) do
          {:found, camino, _explorador} ->
            datos |> registrar_camino(camino) |> detener_exploradores()

          {:continue, explorador} ->
            put_in(datos.exploradores[id], explorador)

          {:done, _explorador} ->
            datos = put_in(datos.exploradores[id], nil)
            put_in(datos.disponibles[id], ahora() + @mission_pause_ms)
        end
    end
  end

  defp expandir_main(datos, actual, vecinos) do
    if datos.objetivo in vecinos do
      camino = reconstruir(datos.main.padres, actual) ++ [datos.objetivo]
      datos |> registrar_camino(camino) |> terminar()
    else
      main =
        Enum.reduce(vecinos, datos.main, fn vecino, main ->
          if Map.has_key?(main.padres, vecino) do
            main
          else
            %{
              main
              | padres: Map.put(main.padres, vecino, actual),
                siguiente: :queue.in(vecino, main.siguiente)
            }
          end
        end)

      semillas = Enum.take(Enum.uniq(Enum.take(vecinos, 256) ++ datos.semillas), @seed_pool_size)
      %{datos | main: main, semillas: semillas}
    end
  end

  defp registrar_camino(datos, camino) do
    if datos.estado.path == [] or length(camino) < length(datos.estado.path) do
      Harness.report(camino)
      %{datos | estado: %{datos.estado | path: camino, state: :found}}
    else
      datos
    end
  end

  defp detener_exploradores(datos) do
    {tareas, pendientes} =
      Enum.reduce(datos.tareas, {%{}, %{}}, fn {ref, trabajo}, {tareas, pendientes} ->
        if MapSet.member?(trabajo.consumidores, :main) do
          trabajo = %{trabajo | consumidores: MapSet.new([:main])}
          {Map.put(tareas, ref, trabajo), Map.put(pendientes, trabajo.url, ref)}
        else
          cancelar(ref, trabajo)
          {tareas, pendientes}
        end
      end)

    if datos.despertar, do: Process.cancel_timer(datos.despertar)

    %{
      datos
      | tareas: tareas,
        pendientes: pendientes,
        exploradores: %{},
        despertar: nil
    }
  end

  defp terminar(%{terminado: true} = datos), do: datos

  defp terminar(datos) do
    Enum.each(datos.tareas, fn {ref, trabajo} -> cancelar(ref, trabajo) end)
    if datos.despertar, do: Process.cancel_timer(datos.despertar)
    if datos.estado.path == [], do: Harness.report_exhausted()
    estado = if datos.estado.path == [], do: :exhausted, else: :found
    :ets.delete_all_objects(datos.cache)

    %{
      datos
      | terminado: true,
        main: %{
          datos.main
          | cola: :queue.new(),
            siguiente: :queue.new(),
            padres: %{},
            esperando: MapSet.new(),
            expandidos: MapSet.new()
        },
        tareas: %{},
        pendientes: %{},
        exploradores: %{},
        semillas: [],
        despertar: nil,
        estado: %{datos.estado | state: estado, frontier_size: 0}
    }
  end

  defp cancelar(ref, trabajo) do
    Process.exit(trabajo.tarea.pid, :kill)
    Process.demonitor(ref, [:flush])
  end

  defp actualizar_snapshot(datos) do
    frontera = :queue.len(datos.main.cola) + :queue.len(datos.main.siguiente)

    frontera =
      Enum.reduce(datos.exploradores, frontera, fn
        {_id, nil}, n -> n
        {_id, explorador}, n -> n + Explorer.frontier_size(explorador)
      end)

    actual =
      case Enum.take(datos.tareas, 1) do
        [{_ref, trabajo}] -> trabajo.url
        [] -> datos.estado.current_url
      end

    %{datos | estado: %{datos.estado | frontier_size: frontera, current_url: actual}}
  end

  defp programar_despertar(%{despertar: ref} = datos) when not is_nil(ref), do: datos

  defp programar_despertar(datos) do
    espera =
      datos.exploradores
      |> Enum.flat_map(fn
        {id, nil} -> [max(Map.get(datos.disponibles, id, ahora()) - ahora(), 0)]
        _ -> []
      end)
      |> Enum.filter(&(&1 > 0))

    if espera == [] do
      datos
    else
      %{datos | despertar: Process.send_after(self(), :despertar, Enum.min(espera))}
    end
  end

  defp reconstruir(padres, url), do: reconstruir(padres, url, [])
  defp reconstruir(_padres, nil, camino), do: camino

  defp reconstruir(padres, url, camino),
    do: reconstruir(padres, Map.fetch!(padres, url), [url | camino])

  defp ahora, do: System.monotonic_time(:millisecond)
end
