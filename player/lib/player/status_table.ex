defmodule Player.StatusTable do
  @moduledoc """
  Tabla ETS con el último estado y el resumen de cada carrera, por pid del contrato.

  `status/1` lee sin pasar por ningún proceso, y la tabla sobrevive a las carreras.
  Este proceso solo la posee y borra las filas cuando muere una carrera.
  """

  use GenServer

  alias WikiRace.Status

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def register(pid, %Status{} = status), do: GenServer.call(__MODULE__, {:register, pid, status})

  def publish(pid, %Status{} = status), do: :ets.insert(@table, {pid, status}) && :ok

  def publish_stats(pid, stats), do: :ets.insert(@table, {{:stats, pid}, stats}) && :ok

  @spec status(pid()) :: Status.t()
  def status(pid), do: lookup(pid, Status.new())

  @spec stats(pid()) :: map() | nil
  def stats(pid), do: lookup({:stats, pid}, nil)

  defp lookup(key, default) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  rescue
    # `status/1` nunca debe fallar, ni siquiera si la tabla se está recreando.
    ArgumentError -> default
  end

  @impl true
  def init(_args) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, pid, status}, _from, monitors) do
    publish(pid, status)
    {:reply, :ok, Map.put(monitors, Process.monitor(pid), pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, monitors) do
    {pid, monitors} = Map.pop(monitors, ref)
    :ets.delete(@table, pid)
    :ets.delete(@table, {:stats, pid})
    {:noreply, monitors}
  end
end
