defmodule Player.StatusStore do
  @moduledoc """
  Guarda en ETS el último reporte de cada búsqueda, identificado por su PID.

  Los coordinadores publican y las consultas leen directamente de la tabla.
  Este proceso solo la mantiene viva y elimina los reportes cuando muere su PID.
  """

  use GenServer

  alias WikiRace.Status

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def register(pid, %Status{} = estado),
    do: GenServer.call(__MODULE__, {:register, pid, estado})

  def publish(pid, %Status{} = estado) do
    true = :ets.insert(__MODULE__, {pid, estado})
    :ok
  end

  def get(pid) do
    case :ets.lookup(__MODULE__, pid) do
      [{^pid, estado}] -> estado
      [] -> exit(:noproc)
    end
  rescue
    ArgumentError -> exit(:noproc)
  end

  @impl true
  def init(_args) do
    :ets.new(__MODULE__, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, pid, estado}, _from, monitores) do
    ref = Process.monitor(pid)
    :ok = publish(pid, estado)
    {:reply, :ok, Map.put(monitores, ref, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _razon}, monitores) do
    case Map.pop(monitores, ref) do
      {nil, _} ->
        {:noreply, monitores}

      {pid, monitores} ->
        :ets.delete(__MODULE__, pid)
        {:noreply, monitores}
    end
  end
end
