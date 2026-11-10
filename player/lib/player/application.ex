defmodule Player.Application do
  @moduledoc """
  Raíz de la aplicación. Cada carrera es un hijo `restart: :temporary` de
  `Player.RaceSup`: un fallo en una carrera no se reinicia ni escala a la raíz.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Player.StatusTable,
      {DynamicSupervisor, strategy: :one_for_one, name: Player.RaceSup}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Player.Supervisor)
  end
end
