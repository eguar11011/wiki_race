defmodule Player.Application do
  @moduledoc """
  Supervisa las búsquedas que la plataforma inicia mediante Player.Crawler.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: Player.CrawlerSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Player.Supervisor)
  end
end
