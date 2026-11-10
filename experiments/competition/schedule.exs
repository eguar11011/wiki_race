# Calendario de la competición Reciprocity vs Exploradores (entrega oficial 87853b1).
#
# Fuente de verdad del calendario. `wiki_race/platform/config/dev.exs` (round_pairs) debe
# coincidir ronda a ronda; `verify_schedule.exs` lo comprueba.
#
# - Ronda 1: prueba de humo y única carrera de calentamiento. Excluida del análisis.
# - Rondas 2-12: bloque A. Permutación de los 11 pares de platform/priv/article_pairs.exs,
#   obtenida con :rand.seed(:exsss, {4218, 4218, 4218}) |> Enum.shuffle (OTP 29). Se fija
#   aquí literalmente para que no dependa de la versión de OTP.
# - Rondas 13-23: bloque B, orden inverso del bloque A, con los slots intercambiados.
#
# Cada entrada: ronda, bloque, si entra en el análisis, par y la implementación en cada slot.

smoke = {"Tiger", "Antarctica"}

block_a = [
  {"Whisk", "Shoehorn"},
  {"Bird", "Nelson Mandela"},
  {"Tiger", "Antarctica"},
  {"Enzyme", "Hong Kong"},
  {"Old Trafford", "Virus"},
  {"Maya civilization", "Protein"},
  {"Solar eclipse", "Spanish language"},
  {"Leopard", "YouTube"},
  {"Raccoon", "Elizabeth II"},
  {"Dinosaur", "Video game"},
  {"Antarctica", "The Beatles"}
]

slots_a = %{"player1" => :reciprocity, "player2" => :exploradores}
slots_b = %{"player1" => :exploradores, "player2" => :reciprocity}

entry = fn round, block, analyzed, {start, target}, slots ->
  %{round: round, block: block, analyzed: analyzed, start: start, target: target, slots: slots}
end

[entry.(1, :smoke, false, smoke, slots_a)] ++
  (block_a |> Enum.with_index(2) |> Enum.map(fn {pair, r} -> entry.(r, :a, true, pair, slots_a) end)) ++
  (block_a |> Enum.reverse() |> Enum.with_index(13) |> Enum.map(fn {pair, r} -> entry.(r, :b, true, pair, slots_b) end))
