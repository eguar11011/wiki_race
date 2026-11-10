defmodule Player.Route do
  @moduledoc """
  Reconstruye un camino desde la tabla de descubrimiento y lo comprueba con las
  mismas condiciones estructurales que `Verifier.check_shape/3`.

  Cada fila de `seen` es `{canónica, url, canónica_del_padre | nil, profundidad}`.
  `insert_new` fija el padre una sola vez, así que la cadena no tiene ciclos.
  """

  alias Player.Links

  @doc "Camino desde el origen hasta `page`, seguido de `suffix`."
  @spec build(:ets.tid(), String.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def build(seen, page, suffix), do: walk(seen, page, suffix)

  defp walk(seen, canon, path) do
    case :ets.lookup(seen, canon) do
      [{^canon, url, nil, _depth}] -> {:ok, [url | path]}
      [{^canon, url, parent, _depth}] -> walk(seen, parent, [url | path])
      [] -> {:error, :missing_parent}
    end
  end

  @spec validate([String.t()], String.t(), String.t()) :: :ok | {:error, term()}
  def validate(path, start_url, target_url) do
    canon = Enum.map(path, &Links.canonical/1)

    cond do
      length(path) < 2 -> {:error, :too_short}
      List.first(canon) != Links.canonical(start_url) -> {:error, :wrong_start}
      List.last(canon) != Links.canonical(target_url) -> {:error, :wrong_target}
      length(Enum.uniq(canon)) != length(canon) -> {:error, :repeated_article}
      true -> :ok
    end
  end
end
