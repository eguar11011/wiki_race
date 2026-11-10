defmodule Player.WikipediaRetryTest do
  use ExUnit.Case, async: true

  alias Player.Wikipedia

  test "recupera una página después de dos errores temporales con espera progresiva" do
    {url, ref} =
      servidor([
        {503, "Temporal", ""},
        {503, "Temporal", ""},
        {200, "<a href=\"Goal\">Objetivo</a>", ""}
      ])

    objetivo = String.replace(url, "/Start", "/Goal")
    assert {:ok, [^objetivo]} = Wikipedia.vecinos(url)
    assert_receive {:solicitud, ^ref, 1, primera}
    assert_receive {:solicitud, ^ref, 2, segunda}
    assert_receive {:solicitud, ^ref, 3, tercera}

    assert segunda - primera >= 200
    assert tercera - segunda >= 400
    refute_receive {:solicitud, ^ref, 4, _}, 100
  end

  for status <- [408, 429, 500, 502, 503, 504] do
    test "reintenta HTTP #{status} y recupera la página" do
      {url, ref} =
        servidor([
          {unquote(status), "Temporal", ""},
          {200, "Recuperado", ""}
        ])

      assert {:ok, "Recuperado"} = Wikipedia.descargar(url)
      assert_receive {:solicitud, ^ref, 1, _}
      assert_receive {:solicitud, ^ref, 2, _}
      refute_receive {:solicitud, ^ref, 3, _}, 100
    end
  end

  test "agota dos reintentos y devuelve el último error sin una cuarta solicitud" do
    {url, ref} =
      servidor([
        {503, "Temporal", ""},
        {503, "Temporal", ""},
        {503, "Todavía no disponible", ""},
        {200, "No debe llegar aquí", ""}
      ])

    assert {:error, razon} = Wikipedia.descargar(url)
    assert razon =~ "HTTP 503"
    assert razon =~ url

    for intento <- 1..3 do
      assert_receive {:solicitud, ^ref, ^intento, _}
    end

    refute_receive {:solicitud, ^ref, 4, _}, 100
  end

  test "recupera una conexión cerrada antes de recibir la respuesta" do
    {url, ref} = servidor([:cerrar, {200, "Recuperado", ""}])

    assert {:ok, "Recuperado"} = Wikipedia.descargar(url)
    assert_receive {:solicitud, ^ref, 1, _}
    assert_receive {:solicitud, ^ref, 2, _}
    refute_receive {:solicitud, ^ref, 3, _}, 100
  end

  for status <- [403, 404, 302] do
    test "no reintenta HTTP #{status} ni sigue redirecciones" do
      {url, ref} =
        servidor([
          {unquote(status), "Permanente", "Location: /content/wiki/Goal\r\n"},
          {200, "No debe llegar aquí", ""}
        ])

      assert {:error, razon} = Wikipedia.descargar(url)
      assert razon =~ "HTTP #{unquote(status)}"
      assert_receive {:solicitud, ^ref, 1, _}
      refute_receive {:solicitud, ^ref, 2, _}, 100
    end
  end

  for status <- [429, 503] do
    test "no reintenta HTTP #{status} antes de un Retry-After que excede el presupuesto" do
      {url, ref} =
        servidor([
          {unquote(status), "Esperar", "Retry-After: 120\r\n"},
          {200, "No debe llegar aquí", ""}
        ])

      descarga = Task.async(fn -> Wikipedia.descargar(url) end)
      assert {:error, razon} = Task.await(descarga, 1_000)
      assert razon =~ "HTTP #{unquote(status)}"
      assert_receive {:solicitud, ^ref, 1, _}
      refute_receive {:solicitud, ^ref, 2, _}, 100
    end
  end

  test "respeta Retry-After de un segundo antes de reintentar" do
    {url, ref} =
      servidor([
        {429, "Esperar", "Retry-After: 1\r\n"},
        {200, "Recuperado", ""}
      ])

    assert {:ok, "Recuperado"} = Wikipedia.descargar(url)
    assert_receive {:solicitud, ^ref, 1, primera}
    assert_receive {:solicitud, ^ref, 2, segunda}
    assert segunda - primera >= 1_000
    refute_receive {:solicitud, ^ref, 3, _}, 100
  end

  for {nombre, headers} <- [
        {"texto", "Retry-After: pronto\r\n"},
        {"número incompleto", "Retry-After: 1 seconds\r\n"},
        {"repetido", "Retry-After: 1\r\nRetry-After: 2\r\n"}
      ] do
    test "un Retry-After #{nombre} no interrumpe la recuperación" do
      {url, ref} =
        servidor([
          {503, "Temporal", unquote(headers)},
          {200, "Recuperado", ""}
        ])

      assert {:ok, "Recuperado"} = Wikipedia.descargar(url)
      assert_receive {:solicitud, ^ref, 1, _}
      assert_receive {:solicitud, ^ref, 2, _}
      refute_receive {:solicitud, ^ref, 3, _}, 100
    end
  end

  # Cada intento abre una conexión nueva; después del guion respondemos 200 para
  # detectar reintentos adicionales en vez de dejarlos bloqueados en accept/1.
  defp servidor(respuestas) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    owner = self()
    ref = make_ref()
    pid = spawn(fn -> atender(listener, respuestas, owner, ref, 1) end)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :gen_tcp.close(listener)
    end)

    {"http://127.0.0.1:#{port}/content/wiki/Start", ref}
  end

  defp atender(listener, respuestas, owner, ref, intento) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, _request} ->
            send(owner, {:solicitud, ref, intento, System.monotonic_time(:millisecond)})

            {respuesta, restantes} =
              case respuestas do
                [respuesta | restantes] -> {respuesta, restantes}
                [] -> {{200, "Solicitud adicional", ""}, []}
              end

            responder(socket, respuesta)
            atender(listener, restantes, owner, ref, intento + 1)

          {:error, _reason} ->
            :gen_tcp.close(socket)
            atender(listener, respuestas, owner, ref, intento)
        end

      {:error, :closed} ->
        :ok
    end
  end

  defp responder(socket, :cerrar), do: :gen_tcp.close(socket)

  defp responder(socket, {status, body, headers}) do
    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 #{status} Response\r\n",
        "Content-Type: text/html\r\n",
        "Content-Length: #{byte_size(body)}\r\n",
        "Connection: close\r\n",
        headers,
        "\r\n",
        body
      ])

    :gen_tcp.close(socket)
  end
end
