defmodule Player.Test.OfficialVerifier do
  @moduledoc """
  Copia literal de `links/2`, `resolve/2`, `canonical/1` y `port/1` de
  `platform/lib/wiki_race_platform/race/verifier.ex` en `c414bb0`.
  """

  def canonical(url) do
    uri = URI.parse(url)
    path = uri.path |> to_string() |> URI.decode() |> String.trim_trailing("/")
    "#{uri.scheme}://#{uri.host}#{port(uri)}#{path}"
  end

  defp port(%URI{scheme: "http", port: 80}), do: ""
  defp port(%URI{scheme: "https", port: 443}), do: ""
  defp port(%URI{port: nil}), do: ""
  defp port(%URI{port: port}), do: ":#{port}"

  def links(body, base) do
    case Floki.parse_document(body) do
      {:ok, document} ->
        document
        |> Floki.attribute("a", "href")
        |> Enum.map(&resolve(&1, base))
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp resolve("#" <> _rest, _base), do: nil
  defp resolve("javascript:" <> _rest, _base), do: nil
  defp resolve("mailto:" <> _rest, _base), do: nil

  defp resolve(href, base) do
    base |> URI.merge(href) |> URI.to_string() |> canonical()
  rescue
    _ -> nil
  end
end

defmodule Player.Test.Fixtures do
  @moduledoc "Un Kiwix simulado: páginas en memoria servidas con el adaptador de Req."

  alias Player.Test.OfficialVerifier

  @base "http://kiwix.test/content/book/"

  def url(title), do: @base <> title

  def html(links) do
    anchors = Enum.map_join(links, "", &~s(<a href="#{&1}">x</a>))
    "<html><body>#{anchors}</body></html>"
  end

  @doc "`pages`: título => lista de enlaces, HTML, `{:redirect, destino}` o `{:status, código}`."
  def adapter(pages, hook \\ fn _url -> :ok end) do
    fn request ->
      address = URI.to_string(request.url)
      hook.(address)

      response =
        case Map.fetch(pages, String.replace_prefix(address, @base, "")) do
          {:ok, {:redirect, destination}} ->
            Req.Response.new(status: 302, headers: [{"location", destination}], body: "")

          {:ok, {:status, status}} ->
            Req.Response.new(status: status, body: "")

          {:ok, links} when is_list(links) ->
            Req.Response.new(status: 200, body: html(links))

          {:ok, body} when is_binary(body) ->
            Req.Response.new(status: 200, body: body)

          :error ->
            Req.Response.new(status: 404, body: "")
        end

      {request, response}
    end
  end

  def options(pages, extra \\ [], hook \\ fn _url -> :ok end) do
    # Por defecto BFS pura, para probar la infraestructura sin la reciprocidad.
    [req_options: [adapter: adapter(pages, hook)], concurrency: 4, strategy: :bfs] ++ extra
  end

  def become_harness do
    :yes = :global.re_register_name(WikiRace.Harness.registered_name(), self())
    :ok
  end

  def eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  @doc "Comprueba cada salto con la copia literal del verificador, siguiendo redirecciones."
  def officially_valid?(path, pages) do
    path
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [from, to] ->
      MapSet.member?(OfficialVerifier.links(body(from, pages), from), OfficialVerifier.canonical(to))
    end)
  end

  defp body(address, pages) do
    case Map.fetch!(pages, String.replace_prefix(address, @base, "")) do
      {:redirect, destination} -> body(address |> URI.merge(destination) |> URI.to_string(), pages)
      links when is_list(links) -> html(links)
      html when is_binary(html) -> html
    end
  end
end
