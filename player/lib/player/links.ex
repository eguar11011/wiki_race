defmodule Player.Links do
  @moduledoc """
  Extracción y canonicalización de enlaces, con la misma semántica que
  `WikiRacePlatform.Race.Verifier` (`links/2`, `resolve/2` y `canonical/1`).

  `extract/2` devuelve, para cada `a[href]`, la forma canónica con la que el
  verificador compara y la URL que se puede pedir y reportar. Esa URL conserva la
  ruta codificada del enlace, porque el verificador resuelve los enlaces de cada
  página contra la URL tal como aparece en el camino.
  """

  @resource_extensions ~w(.avif .css .eot .gif .ico .jpeg .jpg .js .json .mp3 .mp4 .ogg .ogv .pdf .png .svg .ttf .webm .webp .woff .woff2 .xml)
  @namespaces ~w(file image category special help template talk user user_talk wikipedia wikipedia_talk portal mediawiki draft timedtext module book media)

  @spec canonical(String.t()) :: String.t()
  def canonical(url) do
    uri = URI.parse(url)
    path = uri.path |> to_string() |> URI.decode() |> String.trim_trailing("/")
    "#{uri.scheme}://#{uri.host}#{port(uri)}#{path}"
  end

  defp port(%URI{scheme: "http", port: 80}), do: ""
  defp port(%URI{scheme: "https", port: 443}), do: ""
  defp port(%URI{port: nil}), do: ""
  defp port(%URI{port: port}), do: ":#{port}"

  @doc "Enlaces de la página, en orden y sin repetir su forma canónica."
  @spec extract(binary(), String.t()) :: {:ok, [{String.t(), String.t()}]} | :error
  def extract(body, base) do
    with {:ok, document} <- Floki.parse_document(body) do
      links =
        document
        |> Floki.attribute("a", "href")
        |> Enum.flat_map(&resolve(&1, base))
        |> Enum.uniq_by(&elem(&1, 0))

      {:ok, links}
    else
      _ -> :error
    end
  end

  defp resolve("#" <> _rest, _base), do: []
  defp resolve("javascript:" <> _rest, _base), do: []
  defp resolve("mailto:" <> _rest, _base), do: []

  defp resolve(href, base) do
    merged = URI.merge(base, href)
    canon = merged |> URI.to_string() |> canonical()
    # El verificador ignora query y fragmento al comparar; no se piden ni se reportan.
    url = %{merged | query: nil, fragment: nil} |> URI.to_string()
    [{canon, :binary.copy(url)}]
  rescue
    _ -> []
  end

  @doc "Prefijo `origen/content/libro/` de un artículo canónico."
  @spec book_prefix(String.t()) :: {:ok, String.t()} | :error
  def book_prefix(canon) do
    with [origin, rest] <- String.split(canon, "/content/", parts: 2),
         [book, _title] when book != "" <- String.split(rest, "/", parts: 2) do
      {:ok, origin <> "/content/" <> book <> "/"}
    else
      _ -> :error
    end
  end

  @doc "Título de un artículo canónico cuyo prefijo ya se ha comprobado."
  @spec title(String.t(), String.t()) :: String.t()
  def title(canon, prefix) do
    binary_part(canon, byte_size(prefix), byte_size(canon) - byte_size(prefix))
  end

  @doc "Si conviene descargar el enlace. Solo descarta trabajo; nunca afecta a la validez."
  @spec article?(String.t(), String.t()) :: boolean()
  def article?(canon, prefix) do
    if String.starts_with?(canon, prefix) do
      title = canon |> title(prefix) |> String.downcase()
      namespace = title |> String.split(":", parts: 2) |> hd()

      title != "" and namespace not in @namespaces and
        not String.ends_with?(title, @resource_extensions)
    else
      false
    end
  end
end
