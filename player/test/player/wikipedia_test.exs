defmodule Player.WikipediaTest do
  use ExUnit.Case, async: true

  alias Player.Wikipedia

  @base "http://kiwix.test:8080/content/wiki/Elixir"

  describe "extraer_enlaces/2" do
    test "resuelve relativos y absolutos, elimina fragmentos y conserva el orden sin duplicados" do
      html = """
      <a href="BEAM#historia">BEAM</a>
      <a href="./Ruby?version=2&amp;vista=normal">Ruby</a>
      <a href="/content/wiki/Ada%20Lovelace">Ada</a>
      <a href="http://kiwix.test:8080/content/wiki/BEAM/">otra vez BEAM</a>
      <a href="Ada Lovelace#vida">otra vez Ada</a>
      """

      assert {:ok,
              [
                "http://kiwix.test:8080/content/wiki/BEAM",
                "http://kiwix.test:8080/content/wiki/Ruby",
                "http://kiwix.test:8080/content/wiki/Ada%20Lovelace"
              ]} = Wikipedia.extraer_enlaces(html, @base)
    end

    test "permite artículos anidados y títulos con dos puntos que no son namespaces" do
      html = """
      <a href="../A/BEAM">BEAM</a>
      <a href="Star_Trek:_Voyager">Voyager</a>
      <a href="../A/Elixir/Subpagina">subpágina</a>
      """

      assert {:ok,
              [
                "http://kiwix.test:8080/content/wiki/A/BEAM",
                "http://kiwix.test:8080/content/wiki/A/Star_Trek%3A_Voyager",
                "http://kiwix.test:8080/content/wiki/A/Elixir/Subpagina"
              ]} = Wikipedia.extraer_enlaces(html, "http://kiwix.test:8080/content/wiki/A/Elixir")
    end

    test "A, I y M también pueden ser títulos de artículos" do
      html = ~s(<a href="A">A</a><a href="I">I</a><a href="M">M</a>)

      assert {:ok,
              [
                "http://kiwix.test:8080/content/wiki/A",
                "http://kiwix.test:8080/content/wiki/I",
                "http://kiwix.test:8080/content/wiki/M"
              ]} = Wikipedia.extraer_enlaces(html, @base)
    end

    test "descarta otros servidores, puertos, esquemas y libros" do
      html = """
      <a href="https://en.wikipedia.org/wiki/Elixir">Wikipedia pública</a>
      <a href="http://otro.test:8080/content/wiki/BEAM">otro host</a>
      <a href="http://kiwix.test:8081/content/wiki/BEAM">otro puerto</a>
      <a href="https://kiwix.test:8080/content/wiki/BEAM">otro esquema</a>
      <a href="/content/otro/BEAM">otro libro</a>
      <a href="/content/wiki_extra/BEAM">libro con prefijo parecido</a>
      <a href="//kiwix.test:8080/content/wiki/BEAM">mismo servidor</a>
      """

      assert {:ok, ["http://kiwix.test:8080/content/wiki/BEAM"]} =
               Wikipedia.extraer_enlaces(html, @base)
    end

    test "descarta recursos, navegación, namespaces, URLs inválidas y anclas vacías" do
      html = """
      <a>sin href</a><a href="">vacío</a><a href="  ">espacios</a>
      <a href="#top">ancla</a><a href="?q=BEAM">consulta</a>
      <a href="javascript:alert(1)">JavaScript</a><a href="mailto:x@test">correo</a>
      <a href="http://[">URL inválida</a><a href="/">inicio de Kiwix</a>
      <a href="../-/search?q=Elixir">buscador</a>
      <a href="/content/wiki/-/search">navegación del libro</a>
      <a href="/content/wiki/">índice del libro</a>
      <a href="imagen.PNG">imagen</a><a href="style.css">CSS</a>
      <a href="File:BEAM.svg">archivo</a><a href="Category:Languages">categoría</a>
      <a href="Special%3ARandom">especial codificado</a>
      <a href="A/Talk:Elixir">discusión con namespace antiguo</a>
      <a href="/content/wiki/I/imagen">imagen con namespace antiguo</a>
      <a href="%2e%2e/otro/BEAM">traversal codificado</a>
      <a href="BEAM">artículo</a>
      """

      assert {:ok, ["http://kiwix.test:8080/content/wiki/BEAM"]} =
               Wikipedia.extraer_enlaces(html, @base)
    end

    test "una página sin vecinos tiene una lista vacía" do
      assert {:ok, []} = Wikipedia.extraer_enlaces("<p>Isla</p>", @base)
      assert {:error, _} = Wikipedia.extraer_enlaces(nil, @base)
    end
  end

  describe "normalizar_url/1" do
    test "representa espacios, fragmentos, parámetros y barras finales de forma consistente" do
      assert {:ok, "http://kiwix.test:8080/content/wiki/Ada%20Lovelace"} =
               Wikipedia.normalizar_url(
                 "http://kiwix.test:8080/content/wiki/Ada%20Lovelace/?vista=1#vida"
               )
    end

    test "rechaza URLs ajenas a la forma de los artículos antes de descargar" do
      for url <- [
            "https://en.wikipedia.org/content/wiki/Elixir",
            "http://wikipedia.org./content/wiki/Elixir",
            "http://kiwix.test/content/wiki/../otro/Elixir",
            "http://kiwix.test/content/wiki/%2e%2e/otro/Elixir",
            "http://kiwix.test/content/wiki/",
            "http://usuario@kiwix.test/content/wiki/Elixir",
            "/content/wiki/Elixir",
            "http://[",
            nil
          ] do
        assert {:error, _} = Wikipedia.normalizar_url(url)
        assert {:error, _} = Wikipedia.descargar(url)
      end
    end
  end

  describe "HTTP contra un servidor local" do
    test "vecinos/1 conecta la descarga con la extracción" do
      {url, servidor} = servidor_local(200, "<a href=\"BEAM#top\">BEAM</a>")

      assert {:ok, [String.replace(url, "/Elixir", "/BEAM")]} == Wikipedia.vecinos(url)
      Task.await(servidor)
    end

    test "descargar/1 explica los errores HTTP" do
      {url, servidor} = servidor_local(404, "No existe")

      assert {:error, razon} = Wikipedia.descargar(url)
      assert razon =~ "HTTP 404"
      Task.await(servidor)
    end

    test "rechaza una redirección en lugar de seguirla" do
      {url, servidor} =
        servidor_local(302, "", "Location: http://127.0.0.1:1/content/wiki/Otro\r\n")

      assert {:error, razon} = Wikipedia.descargar(url)
      assert razon =~ "HTTP 302"
      Task.await(servidor)
    end
  end

  # Un solo intercambio HTTP real usando OTP; no necesita Plug ni otro servidor.
  defp servidor_local(status, body, headers \\ "") do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    servidor =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

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
      end)

    {"http://127.0.0.1:#{port}/content/wiki/Elixir", servidor}
  end
end
