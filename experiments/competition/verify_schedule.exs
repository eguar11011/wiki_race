# Verifica, sin lanzar carreras, que la plataforma local ejecutará las 23 rondas del
# calendario y que los resultados y el calendario sobreviven a un reinicio.
#
# Compila los módulos reales del torneo de la plataforma (Tournament.Server, Store,
# Fixtures, Standings, Race.Result, Race.Player, Race.Config, Articles, WikiRace.Status) en
# un directorio temporal. Solo sustituye WikiRacePlatform.Race.subscribe/0 y
# Race.Dispatcher.start_race/2, que en la plataforma lanzarían las carreras: aquí registran
# la configuración pedida. Los resultados se simulan con Race.Result.build/3 y se guardan
# con el Store real en un archivo temporal.
#
# Uso (desde experiments/competition/):
#   elixir verify_schedule.exs [../../../wiki_race/platform]

platform = Path.expand(List.first(System.argv()) || "../../../wiki_race/platform")
here = Path.dirname(__ENV__.file)
schedule = elem(Code.eval_file(Path.join(here, "schedule.exs")), 0)
check = fn ok?, message -> IO.puts("#{if ok?, do: "OK  ", else: "FAIL"} #{message}"); ok? || System.halt(1) end

# 1. Configuración efectiva de dev (config.exs + dev.exs, como en el contenedor).
# config.exs llama a Mix.Project.build_path/0: basta con Mix arrancado, sin proyecto.
Mix.start()

config = Config.Reader.read!(Path.join(platform, "config/config.exs"), env: :dev, target: :host)
tournament = config[:wiki_race_platform][:tournament]
configured = Keyword.fetch!(tournament, :round_pairs)
expected = Enum.map(schedule, &{&1.start, &1.target})

check.(tournament[:roster] == ["player1", "player2"], "roster #{inspect(tournament[:roster])}")
check.(tournament[:generator] == :swiss, "generator #{inspect(tournament[:generator])}")
check.(tournament[:total_rounds] == length(schedule), "total_rounds #{tournament[:total_rounds]} = #{length(schedule)} rondas")
check.(configured == expected, "round_pairs de dev.exs coincide con schedule.exs ronda a ronda")

{pool, _} = Code.eval_file(Path.join(platform, "priv/article_pairs.exs"))
pool_pairs = MapSet.new(pool, &{&1.start, &1.target})
check.(Enum.all?(expected, &MapSet.member?(pool_pairs, &1)), "todos los pares están en priv/article_pairs.exs")
analyzed = Enum.filter(schedule, & &1.analyzed)
check.(length(analyzed) == 22 and Enum.count(schedule, &(not &1.analyzed)) == 1, "22 rondas analizadas y 1 de humo")

for block <- [:a, :b] do
  pairs = analyzed |> Enum.filter(&(&1.block == block)) |> Enum.map(&{&1.start, &1.target})
  check.(MapSet.new(pairs) == pool_pairs and length(pairs) == 11, "bloque #{block}: los 11 pares, sin repetir")
end

a = analyzed |> Enum.filter(&(&1.block == :a)) |> Enum.map(&{&1.start, &1.target})
b = analyzed |> Enum.filter(&(&1.block == :b)) |> Enum.map(&{&1.start, &1.target})
check.(b == Enum.reverse(a), "el bloque B es el orden inverso del bloque A")

# 2. Módulos reales de la plataforma, compilados aparte (la app necesita priv/ para Articles).
build = Path.join(System.tmp_dir!(), "wr_verify_#{System.pid()}_#{System.os_time(:microsecond)}")
ebin = Path.join(build, "wiki_race_platform/ebin")
File.mkdir_p!(ebin)
File.ln_s!(Path.join(platform, "priv"), Path.join(build, "wiki_race_platform/priv"))

Code.compile_string("""
defmodule WikiRacePlatform.Race do
  def subscribe, do: :ok
end

defmodule WikiRacePlatform.Race.Dispatcher do
  def start_race(config, _dispatcher) do
    send(:verify_schedule, {:race_requested, config})
    {:ok, %{}}
  end
end
""")

sources =
  ~w(wiki_race/status.ex wiki_race_platform/articles.ex wiki_race_platform/race/config.ex
     wiki_race_platform/race/player.ex wiki_race_platform/race/result.ex
     wiki_race_platform/tournament/fixtures.ex wiki_race_platform/tournament/standings.ex
     wiki_race_platform/tournament/store.ex wiki_race_platform/tournament/server.ex)
  |> Enum.map(&Path.join([platform, "lib", &1]))

{:ok, _modules, _warnings} = Kernel.ParallelCompiler.compile_to_path(sources, ebin, return_diagnostics: true)
File.write!(Path.join(ebin, "wiki_race_platform.app"), ~s({application,wiki_race_platform,[{vsn,"0"},{modules,[]},{applications,[]}]}.))
Code.prepend_path(ebin)
:ok = Application.load(:wiki_race_platform)

alias WikiRacePlatform.Race.{Player, Result}
alias WikiRacePlatform.Tournament.{Server, Store}

Application.put_env(:wiki_race_platform, :tournament, tournament)
Application.put_env(:wiki_race_platform, :scoring, config[:wiki_race_platform][:scoring])
# Valores de docker-compose.yml para el servicio platform.
Application.put_env(:wiki_race_platform, :kiwix, base_url: "http://kiwix1:8080", book: "wikipedia_en_top_nopic")
Process.register(self(), :verify_schedule)

results = Path.join(build, "competition/results.terms")
# Store.start_link/1 evalúa su ruta por defecto aunque reciba `path:`.
Application.put_env(:wiki_race_platform, :tournament_store, data_dir: Path.dirname(results))
nodes = %{"player1" => :player1@player1, "player2" => :player2@player2}

boot = fn path ->
  {:ok, _} = Store.start_link(path: path)
  {:ok, _} = Server.start_link([])
  :ok
end

shutdown = fn ->
  GenServer.stop(Server)
  GenServer.stop(Store)
end

fake_result = fn {label_a, label_b}, round ->
  path = ["http://kiwix1:8080/content/x/S", "http://kiwix1:8080/content/x/T"]

  players =
    for {label, i} <- Enum.with_index([label_a, label_b]) do
      found? = rem(round + i, 2) == 0

      struct!(Player,
        node: nodes[label],
        label: label,
        state: if(found?, do: :found, else: :running),
        best_path: if(found?, do: path),
        best_elapsed_ms: if(found?, do: 1_000),
        first_elapsed_ms: if(found?, do: 1_000)
      )
    end

  Result.build(players, :time_limit, 120_000)
end

# 3. Simulación de las 23 rondas con reinicios de plataforma (Store y Server) tras la
#    ronda 5 y en el cambio de bloque (tras la ronda 12).
boot.(results)

for %{round: round} = entry <- schedule do
  progress = Server.progress()
  pair = Server.current_pair()
  fixture = Server.next_fixture()

  check.(progress.round == round and not progress.complete, "ronda #{round}: la plataforma está en la ronda #{progress.round}")
  check.({pair.start, pair.target} == {entry.start, entry.target}, "ronda #{round}: par #{pair.start} -> #{pair.target}")
  check.(fixture in [{"player1", "player2"}, {"player2", "player1"}], "ronda #{round}: emparejamiento #{inspect(fixture)}")

  {:ok, _} = Server.start_next!(nodes)
  requested =
    receive do
      {:race_requested, config} -> config
    after
      1_000 -> nil
    end

  {start_url, target_url} = WikiRacePlatform.Articles.urls(pair)
  nodes_requested = requested && requested.players |> Enum.map(& &1.node) |> Enum.sort()

  check.(
    requested != nil and requested.start_url == start_url and requested.target_url == target_url and
      requested.time_limit_ms == 120_000 and nodes_requested == [:player1@player1, :player2@player2],
    "ronda #{round}: carrera pedida con #{start_url} -> #{target_url}, 120 s, player1 y player2"
  )

  :ok = Store.append(fake_result.(fixture, round))
  send(Server, {:race_update, %{status: :finished}})

  if round in [5, 12] do
    before = File.read!(results)
    shutdown.()
    boot.(results)
    check.(File.read!(results) == before and length(Store.list()) == round, "reinicio tras la ronda #{round}: #{round} resultados intactos")
    check.(Server.progress().round == round + 1, "reinicio tras la ronda #{round}: el calendario sigue en la ronda #{round + 1}")
  end
end

final = Server.progress()
check.(final.complete and Server.next_fixture() == nil, "tras 23 rondas el torneo está completo y no hay más carreras")
check.(length(Store.list()) == 23, "el Store tiene 23 resultados")
shutdown.()

# 4. Por qué los resultados van a un directorio nuevo: un resultado previo con las mismas
#    etiquetas (como el de la carrera 2) adelantaría el calendario una ronda.
old = Path.join(platform, "priv/data/results.terms")

if File.exists?(old) do
  shifted = Path.join(build, "shifted/results.terms")
  File.mkdir_p!(Path.dirname(shifted))
  File.cp!(old, shifted)
  boot.(shifted)
  pair = Server.current_pair()
  check.(Server.progress().round == 2, "con el results.terms antiguo la primera carrera sería la ronda 2 (#{pair.start} -> #{pair.target})")
  shutdown.()
end

File.rm_rf!(build)
IO.puts("Calendario verificado: 23 carreras, resultados y calendario sobreviven al reinicio.")
