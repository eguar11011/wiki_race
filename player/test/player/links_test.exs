defmodule Player.LinksTest do
  use ExUnit.Case, async: true

  alias Player.Links
  alias Player.Test.OfficialVerifier

  @base "http://kiwix.test:8080/content/book/Page"
  @book "http://kiwix.test:8080/content/book/"

  defp canons(hrefs, base \\ @base) do
    {:ok, links} = Links.extract(page(hrefs), base)
    Enum.map(links, &elem(&1, 0))
  end

  defp page(hrefs), do: Enum.map_join(hrefs, "", &~s(<a href="#{&1}">x</a>))

  # Valores esperados escritos a mano a partir de RFC 3986 (URI.merge) y de
  # Verifier.canonical/1, no obtenidos ejecutando una copia del código.
  @expected [
    {"Foo", @book <> "Foo"},
    {"./Foo", @book <> "Foo"},
    {"../Foo", "http://kiwix.test:8080/content/Foo"},
    {"/content/book/Root", @book <> "Root"},
    {"http://kiwix.test:8080/content/book/Abs", @book <> "Abs"},
    {"http://kiwix.test/content/book/P80", "http://kiwix.test/content/book/P80"},
    {"//kiwix.test:8080/content/book/NoScheme", @book <> "NoScheme"},
    {"http://other.example/z", "http://other.example/z"},
    {"Caf%C3%A9", @book <> "Café"},
    {"A%2FB", @book <> "A/B"},
    {"AC/DC", @book <> "AC/DC"},
    {"Foo?x=1", @book <> "Foo"},
    {"Foo#s", @book <> "Foo"},
    {"Foo/?x=1#y", @book <> "Foo"},
    {"#top", nil},
    {"javascript:x()", nil},
    {"mailto:a@b.c", nil},
    # URI.decode/1 (Elixir 1.20.5) deja intacto un escape inválido: no lanza y el
    # enlace se conserva, igual que en el verificador.
    {"%zz", @book <> "%zz"}
  ]

  test "resolución y forma canónica esperadas" do
    for {href, expected} <- @expected do
      assert canons([href]) == List.wrap(expected), inspect(href)
    end
  end

  test "base con barras en el título" do
    assert canons(["Foo", "../Bar"], @book <> "AC/DC") == [@book <> "AC/Foo", @book <> "Bar"]
  end

  test "base codificada" do
    assert canons(["Foo"], @book <> "Caf%C3%A9_(x)") == [@book <> "Foo"]
  end

  test "solo cuentan los elementos a con href" do
    html = ~s(<area href="Area"><link href="Link"><div data-href="Data"></div><a>sin</a><a href="Ok">y</a>)
    assert {:ok, [{canon, _url}]} = Links.extract(html, @base)
    assert canon == @book <> "Ok"
  end

  test "sin repetidos y en orden de aparición" do
    assert canons(["B", "A", "B#x", "A?y"]) == [@book <> "B", @book <> "A"]
  end

  test "la URL reportable no lleva query ni fragmento y conserva la codificación" do
    {:ok, [{canon, url}]} = Links.extract(page(["Caf%C3%A9?x=1#y"]), @base)
    assert canon == @book <> "Café"
    assert url == @book <> "Caf%C3%A9"
    assert Links.canonical(url) == canon
  end

  # Detección de divergencias con la copia literal del verificador en casos cuya
  # salida depende de Mochiweb o de URI.merge y no se ha fijado a mano.
  test "casos límite coinciden con la copia del verificador" do
    hrefs = ["", " Foo", "Foo ", "a b", "Foo&amp;Bar", "Star_Wars:_X", "File:X.png", "tel:1", "?q", "%zz"]

    for href <- hrefs do
      {:ok, links} = Links.extract(page([href]), @base)
      assert MapSet.new(links, &elem(&1, 0)) == OfficialVerifier.links(page([href]), @base), inspect(href)
    end

    for html <- ["<a href=Foo>x", "<a href='Foo'", "<!-- <a href=\"X\">x</a> --><a href=\"Y\">y</a>", ""] do
      {:ok, links} = Links.extract(html, @base)
      assert MapSet.new(links, &elem(&1, 0)) == OfficialVerifier.links(html, @base), inspect(html)
    end
  end

  test "canonical" do
    assert Links.canonical("http://h:8080/a%20b/?q=1#f") == "http://h:8080/a b"
    assert Links.canonical("http://h:80/a/") == "http://h/a"
    assert Links.canonical("https://h:443/a") == "https://h/a"
  end

  test "article? y book_prefix" do
    prefix = "http://h/content/book/"
    assert Links.article?(prefix <> "Tiger", prefix)
    refute Links.article?(prefix <> "File:X", prefix)
    refute Links.article?(prefix <> "a.png", prefix)
    refute Links.article?("http://h/content/otro/Tiger", prefix)
    assert Links.book_prefix("http://h:1/content/b/T") == {:ok, "http://h:1/content/b/"}
    assert Links.book_prefix("http://h:1/otro/T") == :error
  end
end
