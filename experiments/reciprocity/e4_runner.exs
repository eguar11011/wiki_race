# Banco E4: compara las políticas con Player.Crawler.start/3, sin torneo ni plataforma.
# Código auxiliar: no forma parte de la entrega. Se ejecuta desde player/:
#
#   KIWIX_BASE=http://kiwix1:8080 mix run ../experiments/reciprocity/e4_runner.exs salida.csv
#
# ESTADO: no se ha ejecutado nunca. Ver e4-summary.md.
#
# Una fila por ejecución. La columna `outcome` separa observaciones válidas de las demás:
#
#   found, exhausted  observación válida: la carrera terminó y sus métricas están completas.
#                     `exhausted` es agotamiento real de la frontera (end_reason de la Race).
#   resource_limit    censurada: un límite de recursos rechazó enlaces. Métricas completas.
#   deadline          censurada por el plazo propio de la Race (solo si se configura).
#   timeout           censurada por presupuesto: sin estado terminal dentro de E4_LIMIT_MS.
#                     No es un fallo de infraestructura. Métricas vacías.
#   no_workers        fallo: murieron todos los workers. Métricas completas.
#   stats_missing     fallo: estado terminal sin resumen (o sin end_reason coherente).
#   race_unreachable  fallo: la carrera no respondió a la sincronización. Métricas vacías.
#
# `error` lleva el motivo de stats_missing y race_unreachable. Las métricas vacías nunca son
# ceros: solo las filas found/exhausted se analizan como observaciones.

[output] = System.argv()
base = System.get_env("KIWIX_BASE", "http://kiwix1:8080")
book = System.get_env("KIWIX_BOOK", "wikipedia_en_top_nopic")
repetitions = String.to_integer(System.get_env("E4_REPETITIONS", "10"))
limit_ms = String.to_integer(System.get_env("E4_LIMIT_MS", "120000"))

# Pool público de platform/priv/article_pairs.exs. No se usa dentro del crawler.
pairs = [
  {"Tiger", "Antarctica"},
  {"Bird", "Nelson_Mandela"},
  {"Enzyme", "Hong_Kong"},
  {"Leopard", "YouTube"},
  {"Antarctica", "The_Beatles"},
  {"Dinosaur", "Video_game"}
]

policies = [:bfs, :reverse]

article = fn title -> "#{base}/content/#{book}/#{URI.encode(title)}" end

wait = fn wait, pid, deadline ->
  status = Player.Crawler.status(pid)

  cond do
    status.state in [:found, :exhausted] -> status
    System.monotonic_time(:millisecond) > deadline -> status
    true -> Process.sleep(20) && wait.(wait, pid, deadline)
  end
end

# Sincronización explícita. Race publica el resumen antes del estado terminal, y
# :sys.get_state/1 vuelve cuando la Race ha procesado todos sus mensajes previos
# (finish/3 incluido), así que tras él el resumen existe o falta de verdad.
collect = fn pid, status ->
  if status.state in [:found, :exhausted] do
    try do
      _ = :sys.get_state(pid)

      case Player.Crawler.stats(pid) do
        nil ->
          {:stats_missing, "Crawler.stats/1 devolvió nil con estado #{status.state}", nil}

        %{end_reason: :found} = metrics when status.state == :found ->
          {:found, "", metrics}

        %{end_reason: reason} = metrics
        when status.state == :exhausted and reason in [:exhausted, :resource_limit, :deadline, :no_workers] ->
          {reason, "", metrics}

        metrics ->
          {:stats_missing, "end_reason #{inspect(metrics[:end_reason])} incoherente con estado #{status.state}", nil}
      end
    catch
      :exit, reason -> {:race_unreachable, "sys.get_state: #{inspect(reason)}", nil}
    end
  else
    {:timeout, "", nil}
  end
end

# El motivo puede contener comas o comillas.
csv_text = fn text -> ~s(") <> String.replace(text, ~s("), ~s("")) <> ~s(") end

fields = ~w(pages errors duplicates download_us discovered memory_max first_path_ms path_length
            encounters candidates_checked candidates_confirmed)a

:rand.seed(:exsss, {4218, 4218, 4218})

runs =
  for {source, target} <- pairs, policy <- policies, repetition <- 1..repetitions do
    {source, target, policy, repetition}
  end
  |> Enum.shuffle()

header =
  ["source", "target", "policy", "repetition", "outcome", "error", "state", "path_articles"] ++
    Enum.map(fields, &Atom.to_string/1)

File.write!(output, Enum.join(header, ",") <> "\n")

failures =
  Enum.reduce(runs, 0, fn {source, target, policy, repetition}, failures ->
    {:ok, pid} = Player.Crawler.start(article.(source), article.(target), strategy: policy)
    status = wait.(wait, pid, System.monotonic_time(:millisecond) + limit_ms)
    {outcome, error, metrics} = collect.(pid, status)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      5_000 -> :ok
    end

    values = if metrics, do: Enum.map(fields, &Map.fetch!(metrics, &1)), else: Enum.map(fields, fn _ -> "" end)

    row =
      [source, target, inspect(policy), repetition, outcome, csv_text.(error), status.state, length(status.path)] ++
        values

    File.write!(output, Enum.join(row, ",") <> "\n", [:append])

    if outcome in [:stats_missing, :race_unreachable, :no_workers] do
      IO.puts(:stderr, "E4 ERROR #{source} -> #{target} #{inspect(policy)} rep #{repetition}: #{outcome}: #{error}")
      failures + 1
    else
      failures
    end
  end)

if failures > 0 do
  IO.puts(:stderr, "E4: #{failures} ejecuciones con fallo de infraestructura (ver columna outcome)")
  System.halt(1)
end
