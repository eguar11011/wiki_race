defmodule Player.StrategiesTest do
  # Comparte el nombre global del harness; no puede ser asíncrono.
  use ExUnit.Case, async: false

  alias Player.{Crawler, Frontier, Reverse}
  alias Player.Test.Fixtures

  import Fixtures, only: [url: 1, options: 3]

  setup do
    Fixtures.become_harness()
    :ok
  end

  defp race(pages, strategy, extra \\ [], hook \\ fn _url -> :ok end) do
    {:ok, pid} = Crawler.start(url("S"), url("T"), options(pages, [strategy: strategy] ++ extra, hook))
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  for strategy <- [:bfs, :reverse] do
    describe "#{strategy}" do
      @strategy strategy

      test "conexión directa" do
        pid = race(%{"S" => ["A", "T"], "A" => []}, @strategy)
        assert_receive {:path_found, ^pid, path}, 2_000
        assert path == [url("S"), url("T")]
      end

      test "dos y tres saltos, válidos para el verificador" do
        for pages <- [%{"S" => ["A"], "A" => ["T"], "T" => []}, %{"S" => ["A"], "A" => ["B"], "B" => ["T"], "T" => []}] do
          pid = race(pages, @strategy)
          assert_receive {:path_found, ^pid, path}, 2_000
          assert Fixtures.officially_valid?(path, pages)
        end
      end

      test "sin ruta termina" do
        pid = race(%{"S" => ["A"], "A" => ["B"], "B" => ["S"], "T" => []}, @strategy)
        assert_receive {:exhausted, ^pid}, 3_000
      end

      test "explora todos los artículos" do
        links = for n <- 1..40, do: "P#{n}"
        pages = links |> Map.new(&{&1, []}) |> Map.put("S", links) |> Map.put("T", [])
        pid = race(pages, @strategy, concurrency: 2)
        assert_receive {:exhausted, ^pid}, 5_000
        assert Crawler.stats(pid).discovered == 40
      end
    end
  end

  describe "frontera" do
    test "conserva el orden de llegada y el tamaño" do
      jobs = for n <- 1..5, do: %{canon: "J#{n}", url: "J#{n}", depth: 1, kind: :forward}
      frontier = Frontier.push(Frontier.new(), jobs)
      assert Frontier.size(frontier) == 5

      drained =
        Stream.unfold(frontier, fn frontier ->
          case Frontier.pop(frontier) do
            {job, next} -> {job.canon, next}
            :empty -> nil
          end
        end)
        |> Enum.to_list()

      assert drained == Enum.map(jobs, & &1.canon)
    end
  end

  describe "Reverse (funciones puras)" do
    @prefix "http://h/content/b/"

    test "espera la activación y luego pide el objetivo" do
      reverse = Reverse.new(@prefix <> "T", @prefix <> "T", activation: 2)
      assert {nil, reverse} = Reverse.next(reverse, 1, false)
      assert {%{kind: :probe}, _} = Reverse.next(reverse, 2, false)
    end

    test "sin frontera directa se activa tras el primer artículo" do
      assert {%{kind: :probe}, _} = Reverse.next(Reverse.new("t", "t"), 1, true)
    end

    test "los candidatos ya alcanzados van primero y respetan el tope" do
      links = for title <- ~w(A B C D T), do: {@prefix <> title, @prefix <> title}
      reverse = Reverse.new(@prefix <> "T", @prefix <> "T", limit: 3)
      reverse = Reverse.probed(reverse, links, @prefix, &(&1 == @prefix <> "C"))
      assert Enum.map(reverse.pending, & &1.canon) == [@prefix <> "C", @prefix <> "A", @prefix <> "B"]
    end

    test "turnos: un candidato de cada `every` salvo sin frontera" do
      reverse = %{Reverse.new("t", "t", every: 2) | phase: :checking, pending: [:c1, :c2, :c3]}
      assert {nil, reverse} = Reverse.next(reverse, 9, false)
      assert {:c1, reverse} = Reverse.next(reverse, 9, false)
      assert {:c2, _} = Reverse.next(reverse, 9, true)
    end

    test "abandona con tasa de confirmación baja" do
      reverse = %{Reverse.new("t", "t", min_checked: 3) | phase: :checking, pending: [:x]}
      reverse = reverse |> Reverse.checked(false) |> Reverse.checked(false) |> Reverse.checked(false)
      assert %{phase: :off, pending: []} = reverse
    end
  end

  describe "Reverse (carreras)" do
    @opts [reverse: [activation: 1], concurrency: 2]

    test "si la búsqueda directa resuelve, no descarga el objetivo" do
      table = :ets.new(:requests, [:public])
      hook = fn address -> :ets.update_counter(table, address, 1, {address, 0}) end
      pid = race(%{"S" => ["T"], "T" => []}, :reverse, [], hook)
      assert_receive {:path_found, ^pid, _path}, 2_000
      assert :ets.lookup(table, url("T")) == []
    end

    test "encuentro: la página directa enlaza a un predecesor confirmado" do
      pages = %{"S" => ["A"], "A" => ["B"], "B" => ["T"], "T" => ["B"]}
      hook = fn address -> if String.ends_with?(address, "/A"), do: Process.sleep(200) end
      pid = race(pages, :reverse, @opts, hook)
      assert_receive {:path_found, ^pid, path}, 3_000
      assert path == [url("S"), url("A"), url("B"), url("T")]
      assert Fixtures.officially_valid?(path, pages)
      assert %{candidates_confirmed: 1, encounters: 1} = Crawler.stats(pid)
    end

    test "un candidato ya alcanzado que enlaza al objetivo cierra el camino" do
      pages = %{"S" => ["B"], "B" => ["T"], "T" => ["B"]}
      calls = :counters.new(1, [])

      # La primera descarga de B (la directa) es lenta; la del candidato llega antes.
      hook = fn address ->
        if String.ends_with?(address, "/B") do
          :counters.add(calls, 1, 1)
          if :counters.get(calls, 1) == 1, do: Process.sleep(300)
        end
      end

      pid = race(pages, :reverse, [reverse: [activation: 1], concurrency: 3], hook)
      assert_receive {:path_found, ^pid, path}, 3_000
      assert path == [url("S"), url("B"), url("T")]
      assert Crawler.stats(pid).candidates_confirmed == 1
    end

    test "un enlace del objetivo que no enlaza al objetivo no es predecesor" do
      pid = race(%{"S" => ["A"], "A" => ["C"], "C" => [], "T" => ["C"]}, :reverse, @opts)
      assert_receive {:exhausted, ^pid}, 3_000
      assert Crawler.stats(pid).candidates_confirmed == 0
      refute_received {:path_found, _, _}
    end

    test "con tasa baja abandona la dirección inversa" do
      links = for n <- 1..40, do: "C#{n}"
      pages = links |> Map.new(&{&1, []}) |> Map.put("T", links) |> Map.put("S", ["A"]) |> Map.put("A", [])
      pid = race(pages, :reverse, reverse: [activation: 1, min_checked: 4], concurrency: 2)
      assert_receive {:exhausted, ^pid}, 5_000
      assert Crawler.stats(pid).candidates_checked <= 6
    end

    test "un objetivo que no se puede descargar no detiene la búsqueda" do
      pid = race(%{"S" => ["A"], "A" => [], "T" => {:status, 500}}, :reverse, @opts)
      assert_receive {:exhausted, ^pid}, 3_000
    end

    test "respeta el tope de candidatos" do
      links = for n <- 1..30, do: "C#{n}"
      pages = links |> Map.new(&{&1, []}) |> Map.put("T", links) |> Map.put("S", [])
      pid = race(pages, :reverse, reverse: [activation: 1, limit: 5, min_checked: 99], concurrency: 2)
      assert_receive {:exhausted, ^pid}, 3_000
      assert Crawler.stats(pid).candidates_checked == 5
    end
  end
end
