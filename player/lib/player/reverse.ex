defmodule Player.Reverse do
  @moduledoc """
  Frontera inversa verificada, como funciones puras sobre un mapa de estado.

  1. Espera a que la búsqueda directa procese `activation` artículos (o se quede
     sin trabajo): si la ruta es corta, el objetivo ni se descarga.
  2. Descarga el objetivo. Sus enlaces son candidatos, no predecesores. Primero
     van los que la búsqueda directa ya alcanzó: si se confirman, el camino está
     completo.
  3. Un candidato se confirma si su página enlaza al objetivo. Recibe uno de cada
     `every` turnos, o todos si la frontera directa está vacía.
  4. Si tras `min_checked` candidatos se confirman menos de `min_rate`, se abandona.

  Parámetros de diseño sin calibrar.
  """

  alias Player.Links

  @defaults [activation: 24, limit: 64, every: 4, min_checked: 16, min_rate: 0.1]

  def new(target_canon, target_url, opts \\ []) do
    @defaults
    |> Keyword.merge(opts)
    |> Map.new()
    |> Map.merge(%{
      target_canon: target_canon,
      target_url: target_url,
      phase: :waiting,
      pending: [],
      checked: 0,
      confirmed: 0,
      turns: 0
    })
  end

  @doc "Siguiente trabajo inverso, o `nil` si ahora le toca a la búsqueda directa."
  def next(%{phase: :waiting} = reverse, pages, frontier_empty?) do
    if pages >= reverse.activation or (pages >= 1 and frontier_empty?),
      do: {job(reverse.target_canon, reverse.target_url, :probe), %{reverse | phase: :checking}},
      else: {nil, reverse}
  end

  def next(%{phase: :checking, pending: [candidate | rest]} = reverse, _pages, frontier_empty?) do
    reverse = %{reverse | turns: reverse.turns + 1}

    if frontier_empty? or rem(reverse.turns, reverse.every) == 0,
      do: {candidate, %{reverse | pending: rest}},
      else: {nil, reverse}
  end

  def next(reverse, _pages, _frontier_empty?), do: {nil, reverse}

  @doc "Convierte los enlaces del objetivo en candidatos; los ya alcanzados van primero."
  def probed(reverse, links, prefix, seen?) do
    {reached, unreached} =
      links
      |> Enum.filter(fn {canon, _url} -> canon != reverse.target_canon and Links.article?(canon, prefix) end)
      |> Enum.split_with(fn {canon, _url} -> seen?.(canon) end)

    pending =
      (reached ++ unreached)
      |> Enum.take(reverse.limit)
      |> Enum.map(fn {canon, url} -> job(canon, url, :candidate) end)

    %{reverse | pending: pending}
  end

  def checked(reverse, confirmed?) do
    reverse = %{
      reverse
      | checked: reverse.checked + 1,
        confirmed: reverse.confirmed + if(confirmed?, do: 1, else: 0)
    }

    if reverse.checked >= reverse.min_checked and reverse.confirmed / reverse.checked < reverse.min_rate,
      do: %{reverse | phase: :off, pending: []},
      else: reverse
  end

  def failed(nil, _kind), do: nil
  def failed(reverse, :probe), do: %{reverse | phase: :off}
  def failed(reverse, :candidate), do: checked(reverse, false)
  def failed(reverse, :forward), do: reverse

  defp job(canon, url, kind), do: %{canon: canon, url: url, depth: 0, kind: kind}
end
