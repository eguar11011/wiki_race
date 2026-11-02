defmodule Player.Wikipedia do
  @moduledoc """
  Adapta los artículos del Kiwix al grafo que recorren BFS y DFS.

  Cada URL es un vértice y sus enlaces a artículos son sus vecinos. Los vecinos
  permanecen en el mismo servidor y libro de la página de origen.

  Las redirecciones HTTP se rechazan: seguirlas podría salir del Kiwix. Si una
  instalación redirige un artículo, utiliza directamente su URL final.
  """

  @extensiones_recurso ~w(.avif .css .eot .gif .ico .jpeg .jpg .js .json .mp3 .mp4 .ogg .ogv .pdf .png .svg .ttf .webm .webp .woff .woff2 .xml)
  @espacios_nombres ~w(file image category special help template talk user user_talk wikipedia wikipedia_talk portal mediawiki draft timedtext module book media archivo imagen categoría especial ayuda plantilla discusión usuario usuario_discusión wikipedia_discusión)

  @doc "Descarga un artículo sin seguir redirecciones ni reintentar solicitudes."
  @spec descargar(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def descargar(url) do
    with {:ok, url} <- normalizar_url(url) do
      case Req.get(url,
             redirect: false,
             retry: false,
             receive_timeout: 5_000,
             connect_options: [timeout: 5_000],
             decode_body: false
           ) do
        {:ok, %{status: 200, body: html}} when is_binary(html) -> {:ok, html}

        {:ok, %{status: status}} -> {:error, "Kiwix respondió HTTP #{status} al descargar #{url}"}

        {:error, razon} -> {:error, "No se pudo descargar #{url}: #{Exception.message(razon)}"}
      end
    end
  end

  @doc "Descarga una página y devuelve los artículos a los que enlaza."
  @spec vecinos(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def vecinos(url) do
    with {:ok, html} <- descargar(url) do extraer_enlaces(html, url) end
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
      path = uri.path
        |> URI.decode()
        |> String.trim_trailing("/")
        |> URI.encode(&(URI.char_unreserved?(&1) or &1 == ?/))

      {:ok, URI.to_string(%{ uri | scheme: String.downcase(uri.scheme),
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
      host == "wikipedia.org" or String.ends_with?(host, ".wikipedia.org") -> {:error, "Usa el servidor Kiwix, no wikipedia.org"}

      Enum.any?(segmentos, &(&1 in [".", ".."])) -> {:error, "La URL no puede contener segmentos . ni .."}

      true ->
        case segmentos do
          ["content", _libro | titulo] when titulo != [] ->
            if articulo?(titulo), do: :ok, else: {:error, "La URL no es un artículo"}

          _ -> {:error, "Se esperaba una URL /content/<libro>/<artículo> de Kiwix"}
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

    espacio not in @espacios_nombres and not Enum.any?(@extensiones_recurso, &String.ends_with?(titulo, &1))
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
