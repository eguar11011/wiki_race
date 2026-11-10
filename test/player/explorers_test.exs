defmodule Player.ExplorersTest do
  use ExUnit.Case, async: false

  alias Player.Crawler
  alias WikiRace.Status

  setup do
    name = WikiRace.Harness.registered_name()
    assert :yes = :global.register_name(name, self())
    on_exit(fn -> :global.unregister_name(name) end)
    :ok
  end

  test "the explorer follows five real edges before local BFS and never repeats its prefix" do
    explorer = Player.Explorer.new(["Start", "Seed"], 5, 2)

    explorer =
      Enum.reduce(
        [
          {"Seed", ["Start", "A"]},
          {"A", ["Seed", "B"]},
          {"B", ["A", "C"]},
          {"C", ["B", "D"]},
          {"D", ["C", "Landing"]}
        ],
        explorer,
        fn {url, links}, explorer ->
          assert {:request, ^url, waiting} = Player.Explorer.next(explorer)

          assert {:continue, explorer} =
                   Player.Explorer.receive_result(waiting, url, {:ok, links}, "Goal")

          explorer
        end
      )

    assert explorer.phase == :bfs
    assert {:request, "Landing", waiting} = Player.Explorer.next(explorer)

    assert {:continue, explorer} =
             Player.Explorer.receive_result(
               waiting,
               "Landing",
               {:ok, ["A", "X", "Other"]},
               "Goal"
             )

    assert {:request, "X", waiting} = Player.Explorer.next(explorer)

    assert {:found, path, _finished} =
             Player.Explorer.receive_result(waiting, "X", {:ok, ["Goal"]}, "Goal")

    assert path == ["Start", "Seed", "A", "B", "C", "D", "Landing", "X", "Goal"]
    assert Enum.uniq(path) == path
  end

  test "the local BFS budget limits discovered pages and a failed download consumes its place" do
    explorer = Player.Explorer.new(["Start", "Landing"], 0, 2)
    assert {:request, "Landing", waiting} = Player.Explorer.next(explorer)

    assert {:continue, explorer} =
             Player.Explorer.receive_result(waiting, "Landing", {:ok, ["A", "B", "C"]}, "Goal")

    assert {:request, "A", waiting} = Player.Explorer.next(explorer)

    assert {:done, explorer} =
             Player.Explorer.receive_result(waiting, "A", {:error, "404"}, "Goal")

    assert explorer.fetched_count == 2
    assert {:done, _} = Player.Explorer.next(explorer)
  end

  test "main BFS without explorers preserves its level traversal and exhaustion" do
    for opts <- [
          [max_concurrency: 1, explorer_count: 0],
          [max_concurrency: 3, explorer_count: 0]
        ] do
      {base, ref, counts} =
        server(%{
          "Start" => links(["Left", "Right"]),
          "Left" => links(["Shared", "Start"]),
          "Right" => links(["Shared"]),
          "Shared" => links(["Left"])
        })

      pid = start_crawler(base, "Missing", opts)
      assert %Status{state: :exhausted, path: [], frontier_size: 0} = await_state(pid, :exhausted)
      assert Process.alive?(pid)

      for article <- ["Start", "Left", "Right", "Shared"] do
        assert request_count(counts, article) == 1
      end

      refute_receive {:path_found, ^pid, _path}, 20
      flush_requests(ref)
    end
  end

  test "the contract start callback uses BFS and explorers with the delivery defaults" do
    variables = ~w(
      PLAYER_MAX_CONCURRENCY PLAYER_EXPLORER_PERCENT PLAYER_JUMP_HOPS
      PLAYER_EXPLORER_BUDGET PLAYER_RANDOM_SEED
    )

    restore_environment(variables)
    Enum.each(variables, &System.delete_env/1)
    {base, ref, _counts} = server(%{"Start" => {:wait, links(["Goal"])}})
    assert {:ok, pid} = Crawler.start("#{base}/Start", "#{base}/Goal")
    cleanup_crawler(pid)
    assert_explorer_coordinator(pid)
    assert_receive {:http_request, ^ref, "Start", handler}, 1_000

    assert :sys.get_state(pid).config == %{
             max_concurrency: 32,
             bfs_concurrency: 8,
             explorer_count: 24,
             jump_hops: 10,
             explorer_budget: 32,
             random_seed: nil
           }

    send(handler, {:respond, ref})
    assert %Status{state: :found} = await_state(pid, :found)
  end

  test "the contract start callback ignores obsolete resource environment variables" do
    variables = %{
      "PLAYER_MAX_CONCURRENCY" => "invalid",
      "PLAYER_EXPLORER_PERCENT" => "100",
      "PLAYER_JUMP_HOPS" => "0",
      "PLAYER_EXPLORER_BUDGET" => "-1",
      "PLAYER_RANDOM_SEED" => "invalid"
    }

    restore_environment(Map.keys(variables))
    System.put_env(variables)
    {base, ref, _counts} = server(%{"Start" => {:wait, links(["Goal"])}})
    assert {:ok, pid} = Crawler.start("#{base}/Start", "#{base}/Goal")
    cleanup_crawler(pid)

    assert_explorer_coordinator(pid)
    assert_receive {:http_request, ^ref, "Start", handler}, 1_000

    assert :sys.get_state(pid).config == %{
             max_concurrency: 32,
             bfs_concurrency: 8,
             explorer_count: 24,
             jump_hops: 10,
             explorer_budget: 32,
             random_seed: nil
           }

    send(handler, {:respond, ref})
    assert %Status{state: :found} = await_state(pid, :found)
  end

  test "a held first page does not block start or status and the crawler is supervised" do
    {base, ref, _counts} = server(%{"Start" => {:wait, links(["Goal"])}})

    task =
      Task.async(fn ->
        Crawler.start("#{base}/Start", "#{base}/Goal")
      end)

    assert {:ok, pid} = Task.await(task, 500)
    cleanup_crawler(pid)

    assert Enum.any?(DynamicSupervisor.which_children(Player.CrawlerSupervisor), fn
             {_id, child, _type, _modules} -> child == pid
           end)

    assert_receive {:http_request, ^ref, "Start", handler}, 1_000
    query = Task.async(fn -> Crawler.status(pid) end)
    assert %Status{state: :running, visited_count: 0, path: []} = Task.await(query, 200)
    send(handler, {:respond, ref})

    path = urls(base, ["Start", "Goal"])
    assert_receive {:path_found, ^pid, ^path}, 1_000
    assert %Status{state: :found, path: ^path} = await_state(pid, :found)
  end

  test "the shared download budget caps concurrent HTTP and deduplicates pages between searches" do
    pages = %{
      "Start" => links(["A", "B", "C", "D"]),
      "A" => {:wait, links(["Shared"])},
      "B" => {:wait, links(["Shared"])},
      "C" => {:wait, links(["Shared"])},
      "D" => {:wait, links(["Shared"])},
      "Shared" => {:wait, links(["Start", "A"])}
    }

    {base, ref, counts} = server(pages)
    pid = start_crawler(base, "Missing", max_concurrency: 3, explorer_count: 1)
    assert_receive {:http_request, ^ref, "Start", _}, 1_000
    assert_receive {:http_request, ^ref, first, first_handler}, 1_000
    assert_receive {:http_request, ^ref, second, second_handler}, 1_000
    assert first != second

    # Neither held page has answered: HTTP requests really overlap.
    assert %Status{state: :running} = Crawler.status(pid)
    send(first_handler, {:respond, ref})
    send(second_handler, {:respond, ref})
    release_until_settled(pid, ref)
    assert %Status{state: :exhausted} = Crawler.status(pid)
    assert :ets.lookup_element(counts, :maximum_active, 2) <= 3

    for article <- Map.keys(pages) do
      assert request_count(counts, article) == 1,
             "#{article} was downloaded repeatedly instead of sharing its result"
    end
  end

  test "a transient shared page is retried and its recovered links remain available" do
    {base, ref, counts} =
      server(%{
        "Start" => links(["Left", "Right"]),
        "Left" => links(["Shared"]),
        "Right" => links(["Shared"]),
        "Shared" => {:sequence, [{503, "Temporary"}, {:wait, links(["Goal"])}]}
      })

    pid = start_crawler(base, "Goal", max_concurrency: 3, explorer_count: 1)
    assert_receive {:http_request, ^ref, "Shared", _}, 1_000
    assert_receive {:http_request, ^ref, "Shared", handler}, 2_000

    assert %Status{state: :running} = Crawler.status(pid)
    send(handler, {:respond, ref})
    assert_receive {:path_found, ^pid, path}, 1_000
    assert hd(path) == "#{base}/Start"
    assert List.last(path) == "#{base}/Goal"
    assert length(path) == 4
    assert %Status{state: :found} = await_state(pid, :found)
    assert request_count(counts, "Shared") == 2
    refute_receive {:http_request, ^ref, "Shared", _}, 100
  end

  test "a five-hop explorer reports a real prefix and main BFS later improves it using shared links" do
    {base, ref, counts} =
      server(%{
        "Start" => links(["Short", "Long"]),
        "Short" => {:wait, links(["Shared"])},
        "Long" => links(["L2", "Start"]),
        "L2" => links(["L3", "Long"]),
        "L3" => links(["L4", "L2"]),
        "L4" => links(["L5", "L3"]),
        "L5" => links(["Shared", "L4"]),
        "Shared" => links(["Goal", "L5"])
      })

    # One main slot holds Short. The explorer has the other slot and Long is
    # the only seed that is not already being downloaded.
    pid = start_crawler(base, "Goal", max_concurrency: 2, explorer_count: 1)
    assert_receive {:http_request, ^ref, "Short", short}, 1_000
    first_path = urls(base, ["Start", "Long", "L2", "L3", "L4", "L5", "Shared", "Goal"])
    assert_receive {:path_found, ^pid, ^first_path}, 2_000
    assert Enum.uniq(first_path) == first_path
    assert %Status{state: :found, path: ^first_path} = Crawler.status(pid)

    # Explorer visits must not mark Shared visited in the main BFS. The same
    # cached page now yields a shorter prefix through Short, without more HTTP.
    send(short, {:respond, ref})
    improved = urls(base, ["Start", "Short", "Shared", "Goal"])
    assert_receive {:path_found, ^pid, ^improved}, 1_000
    assert %Status{state: :found, path: ^improved} = Crawler.status(pid)
    assert request_count(counts, "Shared") == 1
    refute_receive {:path_found, ^pid, _}, 100
    assert Process.alive?(pid)
  end

  test "a slow deep explorer does not prevent main BFS from reporting a shorter route" do
    {base, ref, _counts} =
      server(%{
        "Start" => links(["Short", "Long"]),
        "Short" => {:wait, links(["Goal"])},
        "Long" => links(["L2"]),
        "L2" => links(["L3"]),
        "L3" => links(["L4"]),
        "L4" => links(["L5"]),
        "L5" => links(["Deep"]),
        "Deep" => {:wait, links(["Farther"])}
      })

    pid = start_crawler(base, "Goal", max_concurrency: 2, explorer_count: 1)
    assert_receive {:http_request, ^ref, "Short", short}, 1_000
    assert_receive {:http_request, ^ref, "Deep", _deep}, 2_000
    query = Task.async(fn -> Crawler.status(pid) end)
    assert %Status{state: :running} = Task.await(query, 200)

    send(short, {:respond, ref})
    path = urls(base, ["Start", "Short", "Goal"])
    assert_receive {:path_found, ^pid, ^path}, 1_000
    assert %Status{state: :found, path: ^path} = Crawler.status(pid)
    refute_receive {:http_request, ^ref, "Farther", _}, 100
  end

  test "an explorer jumps again from the main prefix when BFS catches its local root" do
    {base, ref, _counts} =
      server(%{
        "Start" => links(["Short", "Long"]),
        "Short" => {:wait, links(["Landing"])},
        "Long" => links(["L2"]),
        "L2" => links(["L3"]),
        "L3" => links(["L4"]),
        "L4" => links(["L5"]),
        "L5" => links(["Landing"]),
        "Landing" => links(["X"]),
        "X" => {:wait, links(["J1"])},
        "J1" => {:wait, ""}
      })

    pid = start_crawler(base, "Missing", max_concurrency: 2, explorer_count: 1)
    assert_receive {:http_request, ^ref, "Short", short}, 1_000
    assert_receive {:http_request, ^ref, "X", x}, 2_000

    # This diagnostic state distinguishes main traversal from explorer cache:
    # HTTP for L2 has finished, but main must still respect its level barrier.
    state = :sys.get_state(pid)
    refute MapSet.member?(state.main.expandidos, "#{base}/L2")
    assert state.exploradores[1].root == "#{base}/Landing"
    assert state.exploradores[1].phase == :bfs

    send(short, {:respond, ref})

    await_coordinator(pid, fn state ->
      MapSet.member?(state.main.expandidos, "#{base}/Landing")
    end)

    # Complete the old local request only after main expanded its root. The
    # next mission must use main's shorter prefix and enter jump mode again.
    send(x, {:respond, ref})
    assert_receive {:http_request, ^ref, "J1", _}, 1_000

    state =
      await_coordinator(pid, fn state ->
        match?(
          %{phase: :jump, remaining: 3, waiting: url} when not is_nil(url),
          state.exploradores[1]
        )
      end)

    assert state.exploradores[1].prefix == urls(base, ["Start", "Short", "Landing", "X", "J1"])
    assert state.exploradores[1].waiting == "#{base}/J1"
    assert %Status{state: :running} = Crawler.status(pid)
  end

  test "killing the crawler stops its linked work and does not restart it" do
    existing_children = crawler_children()

    {base, ref, _counts} =
      server(%{
        "Start" => links(["A", "B", "C"]),
        "A" => {:wait, links(["A1"])},
        "B" => {:wait, links(["B1"])},
        "C" => {:wait, links(["C1"])}
      })

    pid = start_crawler(base, "Goal", max_concurrency: 3, explorer_count: 1)
    assert_receive {:http_request, ^ref, "Start", _}, 1_000
    assert_receive {:http_request, ^ref, _article, _handler}, 1_000
    supervisor = Process.whereis(Player.CrawlerSupervisor)
    {:links, linked} = Process.info(pid, :links)
    workers = Enum.reject(linked, &(&1 == supervisor))
    assert workers != []
    monitors = Enum.map([pid | workers], &{&1, Process.monitor(&1)})
    Process.exit(pid, :kill)

    for {process, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^process, _}, 1_000
    end

    Process.sleep(20)

    assert crawler_children() == existing_children

    refute_receive {:path_found, ^pid, _path}, 100
  end

  defp start_crawler(base, target, opts) do
    assert {:ok, pid} =
             Player.SearchHelper.start("#{base}/Start", "#{base}/#{target}", opts)

    cleanup_crawler(pid)
    pid
  end

  defp cleanup_crawler(pid) do
    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)
  end

  defp assert_explorer_coordinator(pid) do
    assert Enum.any?(DynamicSupervisor.which_children(Player.CrawlerSupervisor), fn
             {_id, ^pid, _type, [Player.ExplorerCoordinator]} -> true
             _ -> false
           end)
  end

  defp restore_environment(variables) do
    original = Map.new(variables, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  defp crawler_children do
    Player.CrawlerSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> MapSet.new()
  end

  defp await_state(pid, expected, attempts \\ 300) do
    status = Crawler.status(pid)

    cond do
      status.state == expected ->
        status

      attempts == 0 ->
        flunk("Expected #{expected}, received #{inspect(status)}")

      true ->
        Process.sleep(10)
        await_state(pid, expected, attempts - 1)
    end
  end

  defp await_coordinator(pid, predicate, attempts \\ 200) do
    state = :sys.get_state(pid, 200)

    cond do
      predicate.(state) ->
        state

      attempts == 0 ->
        flunk("Coordinator did not reach the expected traversal phase")

      true ->
        Process.sleep(10)
        await_coordinator(pid, predicate, attempts - 1)
    end
  end

  defp release_until_settled(pid, ref, attempts \\ 100) do
    receive do
      {:http_request, ^ref, _article, handler} ->
        send(handler, {:respond, ref})
        release_until_settled(pid, ref, attempts)
    after
      20 ->
        cond do
          Crawler.status(pid).state != :running -> :ok
          attempts == 0 -> flunk("Hybrid crawler did not finish its finite graph")
          true -> release_until_settled(pid, ref, attempts - 1)
        end
    end
  end

  defp flush_requests(ref) do
    receive do
      {:http_request, ^ref, _article, _handler} -> flush_requests(ref)
    after
      0 -> :ok
    end
  end

  defp urls(base, articles), do: Enum.map(articles, &"#{base}/#{&1}")
  defp links(articles), do: Enum.map_join(articles, &~s(<a href="#{&1}">#{&1}</a>))
  defp request_count(counts, article), do: :ets.lookup_element(counts, article, 2)

  # Held responses provide explicit barriers instead of depending on HTTP timing.
  defp server(pages) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    owner = self()
    ref = make_ref()
    counts = :ets.new(:explorer_http_counts, [:set, :public])
    :ets.insert(counts, [{:active, 0}, {:maximum_active, 0}])
    server_pid = spawn(fn -> serve(listener, pages, owner, ref, counts) end)

    on_exit(fn ->
      if Process.alive?(server_pid), do: Process.exit(server_pid, :kill)
      :gen_tcp.close(listener)
    end)

    {"http://127.0.0.1:#{port}/content/wiki", ref, counts}
  end

  defp serve(listener, pages, owner, ref, counts) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        handler =
          spawn_link(fn ->
            receive do
              {:socket, socket} -> respond(socket, pages, owner, ref, counts)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, handler)
        send(handler, {:socket, socket})
        serve(listener, pages, owner, ref, counts)

      {:error, _reason} ->
        # Closing the listener must also terminate linked held-response handlers.
        # A normal accept-loop exit would leave them alive after the test ends.
        exit(:shutdown)
    end
  end

  defp respond(socket, pages, owner, ref, counts) do
    with {:ok, request} <- read_headers(socket),
         ["GET", path | _] <- String.split(request, " ") do
      article = String.replace_prefix(path, "/content/wiki/", "")
      attempt = :ets.update_counter(counts, article, {2, 1}, {article, 0})
      active = :ets.update_counter(counts, :active, {2, 1})
      update_maximum(counts, active)
      send(owner, {:http_request, ref, article, self()})

      response =
        case Map.get(pages, article, {404, "Not found"}) do
          {:sequence, responses} -> Enum.at(responses, min(attempt - 1, length(responses) - 1))
          response -> response
        end

      {status, body} =
        case response do
          {:wait, body} ->
            receive do
              {:respond, ^ref} -> {200, body}
            after
              5_000 -> {503, "Test did not release the response"}
            end

          {status, body} ->
            {status, body}

          body when is_binary(body) ->
            {200, body}
        end

      :ets.update_counter(counts, :active, {2, -1})

      :gen_tcp.send(socket, [
        "HTTP/1.1 #{status} Response\r\n",
        "Content-Type: text/html\r\n",
        "Content-Length: #{byte_size(body)}\r\n",
        "Connection: close\r\n\r\n",
        body
      ])
    end

    :gen_tcp.close(socket)
  end

  defp update_maximum(counts, active) do
    previous = :ets.lookup_element(counts, :maximum_active, 2)

    if active > previous do
      case :ets.select_replace(counts, [
             {{:maximum_active, previous}, [], [{{:maximum_active, active}}]}
           ]) do
        1 -> :ok
        0 -> update_maximum(counts, active)
      end
    end
  end

  defp read_headers(socket, accumulated \\ "") do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} ->
        request = accumulated <> chunk

        if String.contains?(request, "\r\n\r\n"),
          do: {:ok, request},
          else: read_headers(socket, request)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
