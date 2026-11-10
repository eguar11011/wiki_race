# Convierte los resultados oficiales de la competición en un CSV, una fila por ronda e
# implementación. Solo lee: el results.terms de la plataforma, schedule.exs, manifest.exs y,
# opcionalmente, los logs capturados de Reciprocity.
#
# Uso (desde experiments/competition/):
#   elixir decode_results.exs [--results RUTA] [--logs ARCHIVO]... [--out CSV]
#
# --results  por defecto ../../../wiki_race/platform/priv/data/competition-2026-11/results.terms
# --logs     salida guardada de `docker compose logs`, en orden cronológico (un archivo por
#            bloque). Aporta end_reason y las métricas propias de Reciprocity.
#
# `outcome` (columna) y `group`:
#   found                   valid      ruta verificada por la plataforma
#   exhausted               valid      frontera agotada de verdad
#   censored_time_limit     censored   sin ruta al llegar el límite de 120 s de la plataforma
#   censored_resource_limit censored   Reciprocity: un límite de recursos rechazó enlaces
#   censored_deadline       censored   Reciprocity: plazo propio (no debería ocurrir)
#   rejected                failure    la plataforma rechazó una ruta reportada (-1.0)
#   operational_failure     failure    jugador caído/en error, sin workers, o sin descargas
#   unclassified            failure    faltan datos para clasificar (p. ej. log no capturado)

{opts, _, _} =
  OptionParser.parse(System.argv(), strict: [results: :string, logs: :keep, out: :string])

here = Path.dirname(__ENV__.file)
schedule = elem(Code.eval_file(Path.join(here, "schedule.exs")), 0)
manifest = elem(Code.eval_file(Path.join(here, "manifest.exs")), 0)

results_path =
  opts[:results] || Path.join(here, "../../../wiki_race/platform/priv/data/competition-2026-11/results.terms")

warn = fn message -> IO.puts(:stderr, "AVISO: " <> message) end

for {name, impl} <- manifest.implementations do
  if impl.commit =~ "PENDIENTE", do: warn.("manifest.exs: commit de #{name} sin fijar")
  if impl.commit =~ "+diff", do: warn.("manifest.exs: #{name} se identifica por un diff sin commit")
end

# --- Resultados oficiales (mismo formato que Tournament.Store) -------------------------
decode = fn
  decode, <<size::32, term::binary-size(size), rest::binary>>, acc ->
    decode.(decode, rest, [:erlang.binary_to_term(term) | acc])

  _decode, <<>>, acc ->
    Enum.reverse(acc)
end

roster = ["player1", "player2"]

entries =
  results_path
  |> File.read!()
  |> then(&decode.(decode, &1, []))
  # Como Tournament.Server: solo cuentan las carreras de los jugadores del roster.
  |> Enum.filter(fn entry -> Enum.all?(entry.result.ranking, &(&1.label in roster)) end)

if length(entries) > length(schedule),
  do: warn.("#{length(entries)} resultados para #{length(schedule)} rondas: sobran entradas")

# --- Logs de Reciprocity ------------------------------------------------------------
fields = fn text -> ~r/(\w+)=(\S+)/ |> Regex.scan(text) |> Map.new(fn [_, k, v] -> {k, v} end) end

events =
  (opts |> Keyword.get_values(:logs))
  |> Enum.flat_map(fn file -> file |> File.read!() |> String.split("\n") end)
  |> Enum.flat_map(fn line ->
    case Regex.run(~r/wikirace_reciprocity event=(race_start|race_end) (.*)$/, line) do
      [_, event, rest] -> [{event, fields.(rest)}]
      nil -> []
    end
  end)

# Cada race_start con su race_end (mismo pid, antes del siguiente race_start de ese pid).
starts =
  events
  |> Enum.with_index()
  |> Enum.filter(fn {{event, _}, _} -> event == "race_start" end)
  |> Enum.map(fn {{_, start}, i} ->
    finish =
      events
      |> Enum.drop(i + 1)
      |> Enum.take_while(fn {event, f} -> not (event == "race_start" and f["race"] == start["race"]) end)
      |> Enum.find_value(fn {event, f} -> event == "race_end" and f["race"] == start["race"] and f end)

    {start, finish}
  end)

title = fn url -> url |> String.split("/") |> List.last() |> URI.decode() |> String.replace("_", " ") end

# Alinea cada ronda con el siguiente race_start de su par (los logs pueden faltar).
{log_by_round, unused} =
  Enum.map_reduce(schedule, starts, fn entry, pending ->
    matches? = fn {s, _} -> title.(s["start"]) == entry.start and title.(s["target"]) == entry.target end

    case Enum.split_while(pending, &(not matches?.(&1))) do
      {_skipped, [match | rest]} -> {{entry.round, match}, rest}
      {_, []} -> {{entry.round, nil}, pending}
    end
  end)

log_by_round = Map.new(log_by_round)
if starts != [] and unused != [], do: warn.("#{length(unused)} race_start sin ronda asignada")

# --- Clasificación --------------------------------------------------------------------
classify = fn impl, player, finish ->
  cond do
    player.rejected? -> "rejected"
    player.path != nil -> "found"
    player.state in [:down, :error, :pending] -> "operational_failure"
    player.state == :running -> "censored_time_limit"
    # Exploradores no tiene plazo ni topes: :exhausted es su BFS principal agotado.
    player.state == :exhausted and impl == :exploradores and player.visited_count > 0 -> "exhausted"
    player.state == :exhausted and impl == :exploradores -> "operational_failure"
    player.state == :exhausted and finish == nil -> "unclassified"
    player.state == :exhausted ->
      case finish["cause"] do
        "exhausted" -> "exhausted"
        "resource_limit" -> "censored_resource_limit"
        "deadline" -> "censored_deadline"
        "no_workers" -> "operational_failure"
        _ -> "unclassified"
      end

    true ->
      "unclassified"
  end
end

group = fn
  o when o in ["found", "exhausted"] -> "valid"
  "censored_" <> _ -> "censored"
  _ -> "failure"
end

# --- CSV ------------------------------------------------------------------------------
header =
  ~w(round block analyzed start target implementation slot commit snapshot_sha256 platform_commit
     race_ended_at_utc ended_by duration_ms decided_by won official_state outcome group
     verified_path rejected path_length elapsed_ms first_elapsed_ms visited_count score
     utilization error end_reason log_pages log_discovered log_elapsed_ms checks)

csv = fn
  nil -> ""
  value when is_binary(value) -> ~s(") <> String.replace(value, ~s("), ~s("")) <> ~s(")
  value -> to_string(value)
end

rows =
  for entry <- schedule,
      official <- [Enum.at(entries, entry.round - 1)],
      official != nil,
      {slot, impl} <- Enum.sort(entry.slots) do
    result = official.result
    player = Enum.find(result.ranking, &(&1.label == slot))
    {_start, finish} = if(impl == :reciprocity, do: log_by_round[entry.round] || {nil, nil}, else: {nil, nil})
    outcome = classify.(impl, player, finish)

    checks =
      [
        player.path && {title.(hd(player.path)), title.(List.last(player.path))} != {entry.start, entry.target} &&
          "path_pair_mismatch",
        impl == :reciprocity and finish != nil and finish["cause"] == "found" and player.path == nil &&
          "found_in_log_not_verified",
        impl == :reciprocity and finish != nil and player.state == :running && "log_end_but_platform_running"
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(";")

    [
      entry.round, entry.block, entry.analyzed, entry.start, entry.target, impl, slot,
      manifest.implementations[impl].commit, manifest.snapshot.sha256, manifest.platform.commit,
      DateTime.to_iso8601(official.ended_at_utc), result.ended_by, result.duration_ms,
      result.decided_by, result.winner != nil and result.winner.label == slot, player.state,
      outcome, group.(outcome), player.path != nil and not player.rejected?, player.rejected?,
      player.path_length, player.elapsed_ms, player.first_elapsed_ms, player.visited_count,
      player.score, player.utilization, player.error, finish && finish["cause"],
      finish && finish["pages"], finish && finish["discovered"], finish && finish["elapsed_ms"], checks
    ]
    |> Enum.map_join(",", csv)
  end

missing = length(schedule) - length(entries)
if missing > 0, do: warn.("#{missing} rondas sin resultado oficial todavía")

output = Enum.join([Enum.join(header, ",") | rows], "\n") <> "\n"

case opts[:out] do
  nil -> IO.write(output)
  path -> File.write!(path, output)
end
