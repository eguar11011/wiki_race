defmodule Player.Crawler do
  @moduledoc """
  Punto de entrada del contrato `WikiRace.Crawler`.

  `start/2` arranca una carrera supervisada y devuelve su pid sin descargar nada.
  `status/1` lee ETS sin pasar por ningún proceso.
  """

  @behaviour WikiRace.Crawler

  alias Player.{Links, Race, StatusTable}

  @impl WikiRace.Crawler
  def start(start_url, target_url), do: start(start_url, target_url, [])

  @doc "Como `start/2`, con opciones de `Player.Race` (estrategia, concurrencia…)."
  def start(start_url, target_url, opts) do
    if Links.canonical(start_url) == Links.canonical(target_url),
      do: {:error, :start_equals_target},
      else: DynamicSupervisor.start_child(Player.RaceSup, {Race, {start_url, target_url, opts}})
  end

  @impl WikiRace.Crawler
  def status(pid), do: StatusTable.status(pid)

  @doc "Resumen de una carrera terminada, o `nil`."
  def stats(pid), do: StatusTable.stats(pid)
end
