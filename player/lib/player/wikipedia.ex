defmodule Player.Wikipedia do
  @moduledoc """
  Adapta los artículos del Kiwix al grafo que recorren BFS y DFS.

  Cada URL es un vértice y sus enlaces a artículos son sus vecinos. Los vecinos
  permanecen en el mismo servidor y libro de la página de origen.

  Las redirecciones HTTP se rechazan: seguirlas podría salir del Kiwix. Si una
  instalación redirige un artículo, utiliza directamente su URL final.

  Los fallos temporales tienen hasta dos reintentos con espera progresiva.
  En la competencia esto ocurre dentro del Task, sin bloquear al coordinador.
  """

  @extensiones_recurso ~w(.avif .css .eot .gif .ico .jpeg .jpg .js .json .mp3 .mp4 .ogg .ogv .pdf .png .svg .ttf .webm .webp .woff .woff2 .xml)
  @espacios_nombres ~w(file image category special help template talk user user_talk wikipedia wikipedia_talk portal mediawiki draft timedtext module book media archivo imagen categoría especial ayuda plantilla discusión usuario usuario_discusión wikipedia_discusión)

  require Logger

  @max_reintentos 2
  @espera_inicial_ms 200
  @variacion_ms 100
  @max_espera_ms 2_000
  @http_temporales [408, 429, 500, 502, 503, 504]

  @doc """
  Descarga un artículo sin seguir redirecciones, con hasta tres intentos totales.

  Reintenta errores temporales de HTTP o transporte; nunca URLs inválidas,
  redirecciones ni errores permanentes como 403/404. Espera 200–300 ms antes
  del segundo intento y 400–500 ms antes del tercero. Para 429/503 respeta
  `Retry-After` hasta 2 segundos; si exige más, devuelve el error sin insistir
  antes del plazo indicado, para no retener un trabajador durante la carrera.
  """
  @spec descargar(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def descargar(url) do
    with {:ok, url} <- normalizar_url(url) do
      intentar_descarga(url, 0)
    end
  end

  defp intentar_descarga(url, reintentos) do
    respuesta =
      Req.get(url,
        redirect: false,
        # Solo este protocolo cuenta los intentos: no duplicar los de Req.
        retry: false,
        receive_timeout: 5_000,
        connect_options: [timeout: 5_000],
        decode_body: false
      )

    case espera_reintento(respuesta, reintentos) do
      {:esperar, espera} ->
        Logger.debug("Reintento #{reintentos + 1}/#{@max_reintentos} de #{url} en #{espera} ms")

        # Duerme el trabajador, no el GenServer. Su vínculo permite cancelarlo
        # incluso durante esta espera si termina la búsqueda.
        Process.sleep(espera)
        intentar_descarga(url, reintentos + 1)

      :terminar ->
        resultado_descarga(respuesta, url)
    end
  end

  defp espera_reintento(_respuesta, reintentos) when reintentos >= @max_reintentos,
    do: :terminar

  defp espera_reintento(respuesta, reintentos) do
    if temporal?(respuesta) do
      espera = @espera_inicial_ms * Integer.pow(2, reintentos)
      espera = espera + :rand.uniform(@variacion_ms + 1) - 1
      indicada = espera_servidor(respuesta)

      if indicada > @max_espera_ms do
        Logger.debug("Sin reintento: Retry-After de #{indicada} ms excede #{@max_espera_ms} ms")
        :terminar
      else
        {:esperar, max(espera, indicada)}
      end
    else
      :terminar
    end
  end

  defp temporal?({:ok, %{status: status}}), do: status in @http_temporales

  defp temporal?({:error, %Req.TransportError{reason: razon}}),
    do: razon in [:timeout, :econnrefused, :closed, :econnreset]

  defp temporal?({:error, %Req.HTTPError{protocol: :http2, reason: razon}}),
    do: razon in [:unprocessed, :pool_not_available]

  defp temporal?(_respuesta), do: false

  defp espera_servidor({:ok, %Req.Response{status: status} = respuesta})
       when status in [429, 503] do
    max(Req.Response.get_retry_after(respuesta) || 0, 0)
  rescue
    # Una cabecera malformada no debe derribar el trabajador: usamos backoff.
    _ -> 0
  end

  defp espera_servidor(_respuesta), do: 0

  defp resultado_descarga({:ok, %{status: 200, body: html}}, _url) when is_binary(html),
    do: {:ok, html}

  defp resultado_descarga({:ok, %{status: status}}, url),
    do: {:error, "Kiwix respondió HTTP #{status} al descargar #{url}"}

  defp resultado_descarga({:error, razon}, url),
    do: {:error, "No se pudo descargar #{url}: #{Exception.message(razon)}"}

  @doc "Descarga una página y devuelve los artículos a los que enlaza."
  @spec vecinos(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def vecinos(url) do
    with {:ok, html} <- descargar(url) do
      extraer_enlaces(html, url)
    end
  end

  @doc "Extrae vecinos de HTML sin hacer solicitudes; conserva el orden de los enlaces."
  @spec extraer_enlaces(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def extraer_enlaces(html, url) when is_binary(html) do
    with {:ok, url} <- normalizar_url(url), {:ok, documento} <- Floki.parse_document(html) do
      base = URI.parse(url)

      enlaces =
        documento
        |> Floki.attribute("a", "href")
        |> Enum.map(&resolver_enlace(&1, base))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {:ok, enlaces}
    end
  end

  def extraer_enlaces(_html, _url), do: {:error, "El HTML debe ser texto"}

  @doc "Valida una URL de artículo y elimina fragmentos, parámetros y barras finales."
  @spec normalizar_url(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def normalizar_url(url) when is_binary(url) do
    with {:ok, uri} <- parsear_url(url), :ok <- validar_articulo(uri) do
      path =
        uri.path
        |> URI.decode()
        |> String.trim_trailing("/")
        |> URI.encode(&(URI.char_unreserved?(&1) or &1 == ?/))

      {:ok,
       URI.to_string(%{
         uri
         | scheme: String.downcase(uri.scheme),
           host: String.downcase(uri.host),
           path: path,
           query: nil,
           fragment: nil
       })}
    end
  end

  def normalizar_url(_url), do: {:error, "La URL debe ser texto"}

  defp parsear_url(url) do
    # Conserva escapes existentes y admite títulos escritos con espacios o tildes.
    codificada = URI.encode(url, &(URI.char_unescaped?(&1) or &1 == ?%))

    case URI.new(codificada) do
      {:ok, uri} -> {:ok, uri}
      {:error, _razon} -> {:error, "La URL no es válida"}
    end
  end

  defp validar_articulo(%URI{scheme: scheme, host: host, userinfo: nil, path: path})
       when scheme in ["http", "https"] and is_binary(host) and host != "" and is_binary(path) do
    host = host |> String.downcase() |> String.trim_trailing(".")
    segmentos = path |> URI.decode() |> String.split("/", trim: true)

    cond do
      host == "wikipedia.org" or String.ends_with?(host, ".wikipedia.org") ->
        {:error, "Usa el servidor Kiwix, no wikipedia.org"}

      Enum.any?(segmentos, &(&1 in [".", ".."])) ->
        {:error, "La URL no puede contener segmentos . ni .."}

      true ->
        case segmentos do
          ["content", _libro | titulo] when titulo != [] ->
            if articulo?(titulo), do: :ok, else: {:error, "La URL no es un artículo"}

          _ ->
            {:error, "Se esperaba una URL /content/<libro>/<artículo> de Kiwix"}
        end
    end
  end

  defp validar_articulo(_uri), do: {:error, "Se esperaba una URL absoluta http(s) de Kiwix"}

  defp articulo?(["A", primero | resto]), do: articulo?([primero | resto])
  defp articulo?([]), do: false
  defp articulo?(["-" | _]), do: false
  defp articulo?([prefijo, _ | _]) when prefijo in ["I", "M"], do: false

  defp articulo?(segmentos) do
    titulo = segmentos |> Enum.join("/") |> String.downcase()
    espacio = titulo |> String.split(":", parts: 2) |> hd()

    espacio not in @espacios_nombres and
      not Enum.any?(@extensiones_recurso, &String.ends_with?(titulo, &1))
  end

  defp resolver_enlace(href, base) do
    href = String.trim(href)

    if href == "" or String.starts_with?(href, ["#", "?"]) do
      nil
    else
      with {:ok, url} <- base |> URI.merge(href) |> URI.to_string() |> normalizar_url() do
        destino = URI.parse(url)

        if origen(base) == origen(destino) and libro(base) == libro(destino), do: url
      else
        {:error, _razon} -> nil
      end
    end
  rescue
    ArgumentError -> nil
  end

  defp origen(uri), do: {uri.scheme, uri.host, uri.port}

  defp libro(uri) do
    ["content", libro | _titulo] = String.split(uri.path, "/", trim: true)
    libro
  end
end
