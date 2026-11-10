defmodule Player.Application do
  @moduledoc """
  Supervisa las búsquedas que la plataforma inicia mediante Player.Crawler.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Player.StatusStore,
      {DynamicSupervisor, strategy: :one_for_one, name: Player.CrawlerSupervisor}
    ]

    # Si desaparece la tabla, también se detienen las búsquedas que la utilizaban.
    Supervisor.start_link(children, strategy: :rest_for_one, name: Player.Supervisor)
  end
end
