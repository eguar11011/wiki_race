defmodule Player.Frontier do
  @moduledoc """
  Frontera de la búsqueda directa: cola FIFO sin barrera entre niveles (BFS asíncrona).

  Un trabajo es `%{canon, url, depth, kind}`.
  """

  def new, do: {:queue.new(), 0}

  def push({queue, size}, jobs), do: {Enum.reduce(jobs, queue, &:queue.in/2), size + length(jobs)}

  def pop({queue, size}) do
    case :queue.out(queue) do
      {{:value, job}, rest} -> {job, {rest, size - 1}}
      {:empty, _queue} -> :empty
    end
  end

  def size({_queue, size}), do: size
end
