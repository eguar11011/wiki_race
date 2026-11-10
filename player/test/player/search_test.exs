defmodule Player.RaceTest do
  # Comparte el nombre global del harness; no puede ser asíncrono.
  use ExUnit.Case, async: false

  alias Player.{Crawler, Route, Stats}
  alias Player.Test.Fixtures
  alias WikiRace.Status

  import Fixtures, only: [url: 1, options: 3, eventually: 1]

  setup do
    Fixtures.become_harness()
    :ok
  end

  defp race(pages, extra \\ [], hook \\ fn _url -> :ok end) do
    {:ok, pid} = Crawler.start(url("S"), url("T"), options(pages, extra, hook))
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp stats(pid), do: Stats.snapshot(:sys.get_state(pid).context.stats)

  describe "contrato" do
    test "start/2 responde sin esperar las descargas" do
      {microseconds, {:ok, pid}} =
        :timer.tc(fn ->
          Crawler.start(url("S"), url("T"), options(%{"S" => ["T"]}, [], fn _ -> Process.sleep(500) end))
        end)

      assert microseconds < 400_000
      assert Process.alive?(pid)
      Process.exit(pid, :kill)
    end

    test "status/1 no bloquea aunque los Fetchers estén ocupados" do
      pid = race(%{"S" => ["T"]}, [], fn _ -> Process.sleep(300) end)
      {microseconds, status} = :timer.tc(fn -> Crawler.status(pid) end)
      assert %Status{} = status
      assert microseconds < 50_000
    end

    test "rechaza origen igual a destino y URL fuera de un libro" do
      assert {:error, _} = Crawler.start(url("S"), url("S"))
      assert {:error, _} = Crawler.start("http://h/otra/S", url("T"))
    end

    test "matar el pid elimina Fetchers, supervisor y tablas" do
      pid = race(%{"S" => ["T"]}, [], fn _ -> Process.sleep(5_000) end)
      assert eventually(fn -> map_size(:sys.get_state(pid).active) > 0 end)
      state = :sys.get_state(pid)
      fetchers = Map.keys(state.workers)
      ref = Process.monitor(pid)

      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
      assert eventually(fn -> not Process.alive?(state.supervisor) end)
      assert eventually(fn -> Enum.all?(fetchers, &(not Process.alive?(&1))) end)
      assert eventually(fn -> :ets.info(state.context.seen) == :undefined end)
      assert eventually(fn -> :ets.info(state.context.goals) == :undefined end)
      assert eventually(fn -> Crawler.status(pid) == Status.new() end)
    end
  end

  describe "rutas" do
    test "conexión directa" do
      pid = race(%{"S" => ["A", "T"], "A" => []})
      assert_receive {:path_found, ^pid, path}, 2_000
      assert path == [url("S"), url("T")]
      assert Crawler.stats(pid).end_reason == :found
    end

    test "dos y tres saltos, válidos para el verificador" do
      for pages <- [%{"S" => ["A"], "A" => ["T"]}, %{"S" => ["A"], "A" => ["B"], "B" => ["T"]}] do
        pid = race(pages)
        assert_receive {:path_found, ^pid, path}, 2_000
        assert Fixtures.officially_valid?(path, pages)
      end
    end

    test "con un solo worker gana el camino más corto" do
      pages = %{"S" => ["A", "B"], "A" => ["C"], "B" => ["T"], "C" => ["T"]}
      pid = race(pages, concurrency: 1)
      assert_receive {:path_found, ^pid, path}, 2_000
      assert path == [url("S"), url("B"), url("T")]
    end

    test "sin ruta y con ciclos termina" do
      pid = race(%{"S" => ["A"], "A" => ["B", "S"], "B" => ["A", "S"]})
      assert_receive {:exhausted, ^pid}, 2_000
      assert Crawler.status(pid).state == :exhausted
      assert Crawler.stats(pid).end_reason == :exhausted
      assert stats(pid).duplicates > 0
      refute_received {:path_found, _, _}
    end

    test "enlaces repetidos no duplican trabajo" do
      pid = race(%{"S" => ["A", "A", "A#x", "A?y=1"], "A" => ["T"]})
      assert_receive {:path_found, ^pid, path}, 2_000
      assert path == [url("S"), url("A"), url("T")]
    end

    test "las redirecciones se resuelven contra la URL del camino" do
      pages = %{"S" => ["R"], "R" => {:redirect, "/content/book/Real"}, "Real" => ["T"]}
      pid = race(pages)
      assert_receive {:path_found, ^pid, path}, 2_000
      assert path == [url("S"), url("R"), url("T")]
      assert Fixtures.officially_valid?(path, pages)
    end

    test "un título con barra conserva su base" do
      pages = %{"S" => ["AC/DC"], "AC/DC" => ["../T"]}
      pid = race(pages)
      assert_receive {:path_found, ^pid, path}, 2_000
      assert Fixtures.officially_valid?(path, pages)
    end

    test "status/1 contiene el camino reportado y se reporta una sola vez" do
      pid = race(%{"S" => ["A", "B"], "A" => ["T"], "B" => ["T"]})
      assert_receive {:path_found, ^pid, path}, 2_000
      assert %Status{state: :found, path: ^path} = Crawler.status(pid)
      Process.sleep(100)
      refute_received {:path_found, _, _}
    end

    test "Route.validate rechaza caminos inválidos" do
      s = url("S")
      t = url("T")
      assert Route.validate([s, t], s, t) == :ok
      assert {:error, :too_short} = Route.validate([s], s, s)
      assert {:error, :wrong_start} = Route.validate([url("X"), t], s, t)
      assert {:error, :wrong_target} = Route.validate([s, url("X")], s, t)
      assert {:error, :repeated_article} = Route.validate([s, url("A"), url("A/"), t], s, t)
    end
  end

  describe "concurrencia y errores" do
    test "respeta la concurrencia configurada y descarga en paralelo" do
      links = for n <- 1..20, do: "P#{n}"
      pages = links |> Map.new(&{&1, []}) |> Map.put("S", links)
      counter = :counters.new(2, [])

      hook = fn _url ->
        :counters.add(counter, 1, 1)
        now = :counters.get(counter, 1)
        if now > :counters.get(counter, 2), do: :counters.put(counter, 2, now)
        Process.sleep(20)
        :counters.sub(counter, 1, 1)
      end

      pid = race(pages, [concurrency: 4], hook)
      assert_receive {:exhausted, ^pid}, 5_000
      assert :counters.get(counter, 2) in 2..4
    end

    test "una URL enlazada desde varias páginas se descarga una vez" do
      parents = for n <- 1..30, do: "P#{n}"
      pages = parents |> Map.new(&{&1, ["Comun"]}) |> Map.put("S", parents) |> Map.put("Comun", [])
      table = :ets.new(:requests, [:public])
      pid = race(pages, [concurrency: 8], fn address -> :ets.update_counter(table, address, 1, {address, 0}) end)
      assert_receive {:exhausted, ^pid}, 5_000
      assert :ets.lookup(table, url("Comun")) == [{url("Comun"), 1}]
    end

    @tag :capture_log
    test "una excepción en una descarga no detiene la carrera" do
      hook = fn address ->
        if String.ends_with?(address, "Malo"), do: raise("fallo")
        if String.ends_with?(address, "/A"), do: Process.sleep(50)
      end

      pid = race(%{"S" => ["Malo", "A"], "A" => ["T"]}, [], hook)
      assert_receive {:path_found, ^pid, path}, 2_000
      assert path == [url("S"), url("A"), url("T")]
      assert stats(pid).errors == 1
    end

    test "matar un Fetcher en plena descarga lo repone" do
      test_pid = self()

      hook = fn address ->
        if String.ends_with?(address, "/S") do
          send(test_pid, {:worker, self()})
          Process.sleep(5_000)
        end
      end

      pid = race(%{"S" => ["T"]}, [concurrency: 1], hook)
      assert_receive {:worker, worker}, 1_000
      Process.exit(worker, :kill)
      assert Fixtures.eventually(fn -> :sys.get_state(pid).replacements == 1 end)
    end

    @tag :capture_log
    test "sin workers posibles la carrera termina en lugar de esperar al plazo" do
      hook = fn _address -> raise "fallo" end
      pid = race(%{"S" => ["T"]}, [concurrency: 1, max_replacements: 0], hook)
      assert_receive {:exhausted, ^pid}, 2_000
      assert Crawler.stats(pid).end_reason == :no_workers
    end

    test "un error HTTP se omite" do
      hook = fn address -> if String.ends_with?(address, "/A"), do: Process.sleep(50) end
      pid = race(%{"S" => ["Roto", "A"], "Roto" => {:status, 500}, "A" => ["T"]}, [], hook)
      assert_receive {:path_found, ^pid, _path}, 2_000
      assert stats(pid).errors == 1
    end

    test "al encontrar la ruta cancela las descargas en curso" do
      links = for n <- 1..8, do: "L#{n}"
      pages = links |> Map.new(&{&1, []}) |> Map.put("S", ["A" | links]) |> Map.put("A", ["T"])
      hook = fn address -> if String.contains?(address, "/L"), do: Process.sleep(5_000) end
      pid = race(pages, [concurrency: 4], hook)
      assert_receive {:path_found, ^pid, _path}, 2_000
      state = :sys.get_state(pid)
      assert state.done and state.workers == %{}
      assert DynamicSupervisor.count_children(state.supervisor).active == 0
    end
  end

  describe "recursos" do
    test "el tope de descubrimiento acota la tabla" do
      links = for n <- 1..200, do: "P#{n}"
      pid = race(links |> Map.new(&{&1, []}) |> Map.put("S", links), max_discovered: 10, concurrency: 2)
      assert_receive {:exhausted, ^pid}, 5_000
      assert Crawler.stats(pid).discovered == 10
      assert Crawler.stats(pid).end_reason == :resource_limit
    end

    test "el límite de memoria detiene el descubrimiento" do
      links = for n <- 1..50, do: "P#{n}"
      pages = links |> Map.new(&{&1, []}) |> Map.put("S", links)
      pid = race(pages, [memory_limit: 1, memory_check_ms: 1], fn _ -> Process.sleep(30) end)
      assert_receive {:exhausted, ^pid}, 5_000
      assert Crawler.stats(pid).discovered == 0
      assert Crawler.stats(pid).end_reason == :resource_limit
    end

    test "sin plazo propio por defecto: la plataforma limita la carrera" do
      pid = race(%{"S" => ["T"]}, [], fn _ -> Process.sleep(200) end)
      assert :sys.get_state(pid).config.deadline_ms == nil
    end

    test "un plazo configurado termina como :exhausted con causa :deadline" do
      pid = race(%{"S" => ["A"], "A" => ["T"]}, [deadline_ms: 50], fn _ -> Process.sleep(1_000) end)
      assert_receive {:exhausted, ^pid}, 2_000
      assert Crawler.status(pid).state == :exhausted
      assert Crawler.stats(pid).end_reason == :deadline
      refute_received {:path_found, _, _}
    end

    test "al terminar vacía la tabla y publica el resumen" do
      pid = race(%{"S" => ["A"], "A" => ["T"]})
      assert_receive {:path_found, ^pid, _path}, 2_000
      assert :ets.info(:sys.get_state(pid).context.seen, :size) == 0
      summary = Crawler.stats(pid)
      assert %{pages: 2, path_length: 3, strategy: :bfs} = summary
      assert summary.first_path_ms >= 0
    end
  end
end
