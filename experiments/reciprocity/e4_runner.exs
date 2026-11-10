# Banco E4: compara las políticas con Player.Crawler.start/3, sin torneo ni plataforma.
# Código auxiliar: no forma parte de la entrega. Se ejecuta desde player/:
#
#   KIWIX_BASE=http://kiwix1:8080 mix run ../experiments/reciprocity/e4_runner.exs salida.csv
#
# ESTADO: no se ha ejecutado nunca. Ver e4-summary.md.

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

fields = ~w(pages errors duplicates download_us discovered memory_max first_path_ms path_length
            encounters candidates_checked candidates_confirmed)a

:rand.seed(:exsss, {4218, 4218, 4218})

runs =
  for {source, target} <- pairs, policy <- policies, repetition <- 1..repetitions do
    {source, target, policy, repetition}
  end
  |> Enum.shuffle()

header = ["source", "target", "policy", "repetition", "state", "path_articles"] ++ Enum.map(fields, &Atom.to_string/1)
File.write!(output, Enum.join(header, ",") <> "\n")

for {source, target, policy, repetition} <- runs do
  {:ok, pid} = Player.Crawler.start(article.(source), article.(target), strategy: policy)
  status = wait.(wait, pid, System.monotonic_time(:millisecond) + limit_ms)
  Process.sleep(10)
  metrics = Player.Crawler.stats(pid) || %{}
  ref = Process.monitor(pid)
  Process.exit(pid, :kill)

  receive do
    {:DOWN, ^ref, _, _, _} -> :ok
  after
    5_000 -> :ok
  end

  row =
    [source, target, inspect(policy), repetition, status.state, length(status.path)] ++
      Enum.map(fields, &Map.get(metrics, &1, ""))

  File.write!(output, Enum.join(row, ",") <> "\n", [:append])
end
