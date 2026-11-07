defmodule Player.CrawlerTest do
  use ExUnit.Case, async: false

  alias Player.Crawler
  alias WikiRace.Status

  setup do
    name = WikiRace.Harness.registered_name()
    assert :yes = :global.register_name(name, self())
    on_exit(fn -> :global.unregister_name(name) end)
    :ok
  end

  test "start returns a supervised pid and status stays responsive during HTTP" do
    {base, server_ref} = server(%{"Start" => {:wait, links(["Goal"])}})
    start_url = "#{base}/Start"
    target_url = "#{base}/Goal"

    # The response is held until this test releases it. Starting must not wait for HTTP.
    start_task = Task.async(fn -> Crawler.start(start_url, target_url) end)
    assert {:ok, pid} = Task.await(start_task, 500)
    cleanup_crawler(pid)

    assert Enum.any?(DynamicSupervisor.which_children(Player.CrawlerSupervisor), fn
             {_id, child, _type, _modules} -> child == pid
           end)

    assert_receive {:http_request, ^server_ref, "/content/wiki/Start", server_pid}, 1_000

    status_task = Task.async(fn -> Crawler.status(pid) end)

    assert %Status{
             current_url: ^start_url,
             visited_count: 0,
             state: :running,
             path: []
           } = Task.await(status_task, 200)

    send(server_pid, {:respond, server_ref})
    assert %Status{state: :found, path: [^start_url, ^target_url]} = await_state(pid, :found)
    assert Process.alive?(pid)
  end

  test "BFS reports the shortest path when it discovers the target" do
    {base, server_ref} =
      server(%{
        "Start" => links(["A", "A#top", "B"]),
        "A" => links(["Start", "A1"]),
        "A1" => links(["A2"]),
        "A2" => links(["Goal"]),
        "B" => links(["Goal"])
      })

    start_url = "#{base}/Start"
    target_url = "#{base}/Goal"
    pid = start_crawler(start_url, target_url, max_concurrency: 1)
    path = [start_url, "#{base}/B", target_url]

    assert_receive {:path_found, ^pid, ^path}, 2_000
    assert %Status{state: :found, path: ^path, visited_count: 3} = await_state(pid, :found)
    assert Process.alive?(pid)

    for article <- ["Start", "A", "B"] do
      request_path = "/content/wiki/#{article}"
      assert_receive {:http_request, ^server_ref, ^request_path, _server_pid}
    end

    # A1 was already pending. Neither that longer branch nor the target needs a fetch.
    refute_receive {:http_request, ^server_ref, _path, _server_pid}, 100
  end

  test "HTTP failures do not stop the remaining branches and cycles are fetched once" do
    {base, server_ref} =
      server(%{
        "Start" => links(["Ghost", "Left", "Right", "Left"]),
        "Ghost" => {404, "Not found"},
        "Left" => links(["Shared", "Start"]),
        "Right" => links(["Shared"]),
        "Shared" => links(["Left"])
      })

    pid = start_crawler("#{base}/Start", "#{base}/Unreachable")

    assert %Status{state: :exhausted, frontier_size: 0, visited_count: 4, path: []} =
             await_state(pid, :exhausted)

    assert Process.alive?(pid)

    for article <- ["Start", "Ghost", "Left", "Right", "Shared"] do
      request_path = "/content/wiki/#{article}"
      assert_receive {:http_request, ^server_ref, ^request_path, _server_pid}
    end

    refute_receive {:http_request, ^server_ref, _path, _server_pid}, 100
    refute_receive {:path_found, ^pid, _path}
  end

  test "downloads overlap but the next BFS level waits for the slow shortest branch" do
    {base, server_ref} =
      server(%{
        "Start" => links(["Slow", "Fast"]),
        "Slow" => {:wait, links(["Goal"])},
        "Fast" => {:wait, links(["Deep"])},
        "Deep" => links(["Goal"])
      })

    pid = start_crawler("#{base}/Start", "#{base}/Goal", max_concurrency: 2)
    assert_receive {:http_request, ^server_ref, "/content/wiki/Start", _}, 1_000
    assert_receive {:http_request, ^server_ref, "/content/wiki/Slow", slow}, 1_000
    assert_receive {:http_request, ^server_ref, "/content/wiki/Fast", fast}, 1_000

    # Both requests arrived before either response was released: real overlap.
    send(fast, {:respond, server_ref})
    assert %Status{state: :running, frontier_size: 1} = await_visits(pid, 2)

    # Fast discovered Deep, but Slow might still produce a shorter path.
    refute_receive {:http_request, ^server_ref, "/content/wiki/Deep", _}, 100
    query = Task.async(fn -> Crawler.status(pid) end)
    assert %Status{state: :running} = Task.await(query, 200)

    send(slow, {:respond, server_ref})
    path = ["#{base}/Start", "#{base}/Slow", "#{base}/Goal"]
    assert_receive {:path_found, ^pid, ^path}, 1_000
    assert %Status{state: :found, path: ^path} = Crawler.status(pid)
    refute_receive {:http_request, ^server_ref, "/content/wiki/Deep", _}, 100
  end

  test "the concurrency limit is respected and free slots are reused within the level" do
    {base, server_ref} =
      server(%{
        "Start" => links(["A", "B", "C", "D"]),
        "A" => {:wait, ""},
        "B" => {:wait, ""},
        "C" => {:wait, ""},
        "D" => {:wait, ""}
      })

    pid = start_crawler("#{base}/Start", "#{base}/Goal", max_concurrency: 2)
    assert_receive {:http_request, ^server_ref, "/content/wiki/Start", _}, 1_000
    assert_receive {:http_request, ^server_ref, "/content/wiki/A", a}, 1_000
    assert_receive {:http_request, ^server_ref, "/content/wiki/B", b}, 1_000
    refute_receive {:http_request, ^server_ref, _path, _}, 100
    assert %Status{frontier_size: 2, visited_count: 1} = Crawler.status(pid)

    send(b, {:respond, server_ref})
    assert_receive {:http_request, ^server_ref, "/content/wiki/C", c}, 1_000
    refute_receive {:http_request, ^server_ref, _path, _}, 100

    send(c, {:respond, server_ref})
    assert_receive {:http_request, ^server_ref, "/content/wiki/D", d}, 1_000
    send(a, {:respond, server_ref})
    send(d, {:respond, server_ref})
    assert %Status{state: :exhausted, visited_count: 5} = await_state(pid, :exhausted)
  end

  test "a temporary failure is retried without losing the shortest path or blocking status" do
    {base, server_ref} =
      server(%{
        "Start" => links(["Slow", "Fast"]),
        "Slow" =>
          {:sequence,
           [
             {503, "Temporal", "Retry-After: 1\r\n"},
             {:wait, links(["Goal"])}
           ]},
        "Fast" => links(["Deep"]),
        "Deep" => links(["Goal"])
      })

    pid = start_crawler("#{base}/Start", "#{base}/Goal", max_concurrency: 2)
    assert_receive {:http_request, ^server_ref, "/content/wiki/Slow", _}, 1_000
    assert %Status{state: :running, frontier_size: 1} = await_visits(pid, 2)

    query = Task.async(fn -> Crawler.status(pid) end)
    assert %Status{state: :running} = Task.await(query, 200)
    refute_receive {:http_request, ^server_ref, "/content/wiki/Deep", _}, 100

    assert_receive {:http_request, ^server_ref, "/content/wiki/Slow", retry_handler}, 2_000
    send(retry_handler, {:respond, server_ref})

    path = ["#{base}/Start", "#{base}/Slow", "#{base}/Goal"]
    assert_receive {:path_found, ^pid, ^path}, 1_000
    assert %Status{state: :found, path: ^path, visited_count: 3} = Crawler.status(pid)
    refute_receive {:http_request, ^server_ref, "/content/wiki/Deep", _}, 100
    refute_receive {:http_request, ^server_ref, "/content/wiki/Slow", _}, 100
  end

  test "exhausting retries allows the remaining BFS levels to finish" do
    {base, server_ref} =
      server(%{
        "Start" => links(["Broken", "Working"]),
        "Broken" => {503, "Temporal"},
        "Working" => links(["Next"]),
        "Next" => ""
      })

    pid = start_crawler("#{base}/Start", "#{base}/Goal", max_concurrency: 2)
    assert %Status{state: :exhausted, visited_count: 3} = await_state(pid, :exhausted)

    for _ <- 1..3 do
      assert_receive {:http_request, ^server_ref, "/content/wiki/Broken", _}
    end

    assert_receive {:http_request, ^server_ref, "/content/wiki/Next", _}
    refute_receive {:http_request, ^server_ref, "/content/wiki/Broken", _}, 100
  end

  test "killing the crawler during retry backoff prevents later attempts" do
    {base, server_ref} = server(%{"Start" => {503, "Temporal", "Retry-After: 1\r\n"}})
    pid = start_crawler("#{base}/Start", "#{base}/Goal")
    assert_receive {:http_request, ^server_ref, "/content/wiki/Start", _}, 1_000
    assert [worker] = worker_pids(pid)
    ref = Process.monitor(worker)

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
    refute_receive {:http_request, ^server_ref, "/content/wiki/Start", _}, 1_100
  end

  test "finding a path cancels another worker's retry backoff" do
    {base, server_ref} =
      server(%{
        "Start" => links(["Slow", "Fast"]),
        "Slow" => {503, "Temporal", "Retry-After: 1\r\n"},
        "Fast" => {:wait, links(["Goal"])}
      })

    pid = start_crawler("#{base}/Start", "#{base}/Goal", max_concurrency: 2)
    assert_receive {:http_request, ^server_ref, "/content/wiki/Slow", _}, 1_000
    assert_receive {:http_request, ^server_ref, "/content/wiki/Fast", handler}, 1_000
    send(handler, {:respond, server_ref})

    path = ["#{base}/Start", "#{base}/Fast", "#{base}/Goal"]
    assert_receive {:path_found, ^pid, ^path}, 1_000
    refute_receive {:http_request, ^server_ref, "/content/wiki/Slow", _}, 1_100
    assert %Status{state: :found, path: ^path, visited_count: 2} = Crawler.status(pid)
  end

  test "finding the target cancels the other downloads and keeps a stable result" do
    {base, server_ref} =
      server(%{
        "Start" => links(["Slow", "Fast"]),
        "Slow" => {:wait, links(["Other"])},
        "Fast" => {:wait, links(["Goal"])}
      })

    pid = start_crawler("#{base}/Start", "#{base}/Goal", max_concurrency: 2)
    assert_receive {:http_request, ^server_ref, "/content/wiki/Slow", slow}, 1_000
    assert_receive {:http_request, ^server_ref, "/content/wiki/Fast", fast}, 1_000
    workers = worker_pids(pid)
    assert length(workers) == 2
    monitors = Enum.map(workers, fn worker -> {worker, Process.monitor(worker)} end)

    send(fast, {:respond, server_ref})
    path = ["#{base}/Start", "#{base}/Fast", "#{base}/Goal"]
    assert_receive {:path_found, ^pid, ^path}, 1_000

    for {worker, ref} <- monitors do
      assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 1_000
    end

    send(slow, {:respond, server_ref})
    refute_receive {:path_found, ^pid, _}, 100
    assert %Status{state: :found, path: ^path, frontier_size: 0} = Crawler.status(pid)
    assert Process.alive?(pid)
  end

  test "a crashed worker releases its slot without crashing or stalling BFS" do
    {base, server_ref} =
      server(%{
        "Start" => links(["A", "B", "C"]),
        "A" => {:wait, ""},
        "B" => {:wait, ""},
        "C" => {:wait, ""}
      })

    pid = start_crawler("#{base}/Start", "#{base}/Goal", max_concurrency: 2)
    assert_receive {:http_request, ^server_ref, "/content/wiki/A", a}, 1_000
    assert_receive {:http_request, ^server_ref, "/content/wiki/B", b}, 1_000
    [worker | _] = worker_pids(pid)
    Process.exit(worker, :kill)
    assert_receive {:http_request, ^server_ref, "/content/wiki/C", c}, 1_000

    for handler <- [a, b, c], do: send(handler, {:respond, server_ref})
    assert %Status{state: :exhausted, visited_count: 3} = await_state(pid, :exhausted)
    assert Process.alive?(pid)
  end

  test "killing the crawler stops all active downloads without restarting the search" do
    {base, server_ref} =
      server(%{
        "Start" => links(["A", "B"]),
        "A" => {:wait, links(["Goal"])},
        "B" => {:wait, links(["Goal"])}
      })

    existing_children = crawler_children()
    pid = start_crawler("#{base}/Start", "#{base}/Goal", max_concurrency: 2)

    assert_receive {:http_request, ^server_ref, "/content/wiki/A", _}, 1_000
    assert_receive {:http_request, ^server_ref, "/content/wiki/B", _}, 1_000

    workers = worker_pids(pid)
    assert length(workers) == 2
    monitors = Enum.map(workers, fn worker -> {worker, Process.monitor(worker)} end)
    crawler_ref = Process.monitor(pid)

    Process.exit(pid, :kill)

    assert_receive {:DOWN, ^crawler_ref, :process, ^pid, :killed}, 1_000

    for {worker, worker_ref} <- monitors do
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 1_000
    end

    await_children(existing_children)
  end

  test "invalid endpoints are rejected before requesting any page" do
    {base, server_ref} = server(%{})
    start_url = "#{base}/Start"

    assert {:error, :inicio_igual_al_objetivo} = Crawler.start(start_url, start_url)

    for target_url <- [
          "http://another.test/content/wiki/Goal",
          String.replace(base, "/wiki", "/another_book") <> "/Goal"
        ] do
      assert {:error, :distinto_servidor_o_libro} = Crawler.start(start_url, target_url)
    end

    assert {:error, _reason} = Crawler.start(nil, "#{base}/Goal")

    for concurrency <- [0, -1, "2", nil] do
      assert {:error, :max_concurrency_invalida} =
               Crawler.start(start_url, "#{base}/Goal", max_concurrency: concurrency)
    end

    refute_receive {:http_request, ^server_ref, _path, _server_pid}, 100
  end

  defp start_crawler(start_url, target_url, opts \\ []) do
    assert {:ok, pid} = Crawler.start(start_url, target_url, opts)
    cleanup_crawler(pid)
    pid
  end

  defp worker_pids(pid) do
    supervisor = Process.whereis(Player.CrawlerSupervisor)
    {:links, links} = Process.info(pid, :links)
    Enum.reject(links, &(&1 == supervisor))
  end

  defp await_visits(pid, expected, attempts \\ 200) do
    status = Crawler.status(pid)

    cond do
      status.visited_count == expected ->
        status

      attempts == 0 ->
        flunk("Expected #{expected} visits, received #{inspect(status)}")

      true ->
        Process.sleep(10)
        await_visits(pid, expected, attempts - 1)
    end
  end

  defp cleanup_crawler(pid) do
    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)
  end

  defp await_state(pid, expected) do
    await_state(pid, expected, System.monotonic_time(:millisecond) + 2_000)
  end

  defp await_state(pid, expected, deadline) do
    status = Crawler.status(pid)

    cond do
      status.state == expected ->
        status

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("Expected #{inspect(expected)}, received #{inspect(status)}")

      true ->
        Process.sleep(10)
        await_state(pid, expected, deadline)
    end
  end

  defp crawler_children do
    Player.CrawlerSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> MapSet.new()
  end

  defp await_children(expected) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    await_children(expected, deadline)
  end

  defp await_children(expected, deadline) do
    actual = crawler_children()

    cond do
      actual == expected ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("Crawler was restarted: #{inspect(actual)}")

      true ->
        Process.sleep(10)
        await_children(expected, deadline)
    end
  end

  defp links(articles) do
    Enum.map_join(articles, fn article -> ~s(<a href="#{article}">#{article}</a>) end)
  end

  # A real local HTTP server keeps these tests independent of Kiwix and Docker.
  # A {:wait, body} page deliberately withholds its response until the test releases it.
  defp server(pages) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    owner = self()
    ref = make_ref()
    counts = :ets.new(:request_counts, [:set, :public])
    server_pid = spawn(fn -> serve(listener, pages, owner, ref, counts) end)

    on_exit(fn ->
      if Process.alive?(server_pid), do: Process.exit(server_pid, :kill)
      :gen_tcp.close(listener)
    end)

    {"http://127.0.0.1:#{port}/content/wiki", ref}
  end

  defp serve(listener, pages, owner, ref, counts) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        # Each connection has its own handler, so one held response does not
        # prevent the test server from accepting other concurrent requests.
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
        :ok
    end
  end

  defp respond(socket, pages, owner, ref, counts) do
    with {:ok, request} <- read_headers(socket),
         ["GET", path | _rest] <- String.split(request, " ") do
      send(owner, {:http_request, ref, path, self()})
      article = String.replace_prefix(path, "/content/wiki/", "")
      attempt = :ets.update_counter(counts, path, {2, 1}, {path, 0})

      response =
        case Map.get(pages, article, {404, "Not found"}) do
          {:sequence, responses} -> Enum.at(responses, min(attempt - 1, length(responses) - 1))
          response -> response
        end

      {status, body, headers} =
        case response do
          {:wait, body} ->
            receive do
              {:respond, ^ref} -> {200, body, ""}
            after
              5_000 -> {503, "Test did not release the response", ""}
            end

          {status, body} ->
            {status, body, ""}

          {status, body, headers} ->
            {status, body, headers}

          body when is_binary(body) ->
            {200, body, ""}
        end

      :gen_tcp.send(socket, [
        "HTTP/1.1 #{status} Response\r\n",
        "Content-Type: text/html\r\n",
        "Content-Length: #{byte_size(body)}\r\n",
        "Connection: close\r\n",
        headers,
        "\r\n",
        body
      ])
    end

    :gen_tcp.close(socket)
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
