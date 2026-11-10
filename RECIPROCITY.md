# Reciprocity (rama `feature/reciprocity`)

Crawler experimental para WikiRace: BFS asíncrona con exploración inversa selectiva y
verificación de reciprocidad. Es trabajo experimental, independiente de la entrega oficial del
equipo (`main` / tag `final`), que no se modifica desde esta rama.

## Requisitos

- Elixir 1.20 y Erlang/OTP 28 (versiones de referencia en `.tool-versions`: `elixir 1.20.2-otp-28`,
  `erlang 28.5`). Se ha compilado y probado también con Elixir 1.20.5 / OTP 29.
- Hex (`mix local.hex`). Dependencias: solo `req` y `floki` (`player/mix.exs`, `player/mix.lock`).
- Docker, para correr la plataforma y Kiwix (ver `RUNNING.md`).

## Instalar, compilar y probar

```
cd player
mix deps.get
mix compile --force --warnings-as-errors
mix test
```

## Código

`player/lib/player/`: `crawler.ex` (contrato `WikiRace.Crawler`), `race.ex` (carrera,
coordinación y terminación), `fetcher.ex` (descargas), `frontier.ex` (BFS FIFO), `reverse.ex`
(reciprocidad, funciones puras), `links.ex` (extracción y forma canónica, igual que el
verificador), `route.ex`, `stats.ex`, `status_table.ex`.

`Player.Crawler.start/3` acepta opciones de `Player.Race` (`strategy: :reverse | :bfs`,
`concurrency`, `deadline_ms`, ...). Sin plazo propio por defecto: la plataforma limita la
carrera. `Player.Crawler.stats/1` devuelve un resumen con `end_reason`
(`found`, `exhausted`, `deadline`, `no_workers`, `resource_limit`), publicado antes del reporte
al harness. Cada carrera escribe dos líneas de log `wikirace_reciprocity event=race_start|race_end`.

## Experimentos

- `experiments/reciprocity/`: diseño y herramientas de E2-E4 (`e4_runner.exs`).
- `experiments/competition/`: protocolo, calendario y herramientas de la competición contra la
  entrega oficial de Exploradores (`87853b1`). Requiere un clon de `FLAGlab/wiki_race` con la
  configuración descrita en `protocol.md`. Los resultados y logs no se versionan.
