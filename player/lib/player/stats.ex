defmodule Player.Stats do
  @moduledoc """
  Contadores de una carrera para el resumen final y el banco E4.
  Ninguna decisión de la búsqueda los lee.
  """

  @keys [
    :pages,
    :errors,
    :duplicates,
    :download_us,
    :encounters,
    :candidates_checked,
    :candidates_confirmed,
    :first_path_ms,
    :path_length
  ]
  @index @keys |> Enum.with_index(1) |> Map.new()

  def new, do: :counters.new(length(@keys), [:write_concurrency])
  def add(ref, key, amount \\ 1), do: :counters.add(ref, Map.fetch!(@index, key), amount)
  def put(ref, key, value), do: :counters.put(ref, Map.fetch!(@index, key), value)
  def snapshot(ref), do: Map.new(@keys, &{&1, :counters.get(ref, Map.fetch!(@index, &1))})
end
