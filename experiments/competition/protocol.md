# Competición 1: Reciprocity vs Exploradores (entrega oficial)

**Estado: preparada, sin ejecutar.** Resultados preliminares: snapshot `top_nopic`, no `all_nopic`.

## Qué se compara

| | Reciprocity | Exploradores |
|---|---|---|
| Código | `wiki_race_reciprocity/player`, rama `feature/reciprocity` (sin commit: base `0d56a25` más el diff de `player/` registrado en `manifest.exs`) | `wiki_race_exploradores`: worktree *detached* en la entrega oficial `87853b159f55bb364df9767637452befbbb658ab` (`main` y tag `final` en GitHub), árbol `a70efad0…`. Proyecto en la raíz |
| Algoritmo | BFS asíncrona con reciprocidad verificada (`strategy: :reverse`) | `Player.ExplorerCoordinator`: BFS concurrente por niveles más 24 exploradores aleatorios (10 saltos y BFS local de 32 artículos), sin semilla fija |
| Concurrencia | 16 | 32 (8 reservadas al BFS) |
| HTTP | Sigue redirecciones, sin reintentos, 5 s | No sigue redirecciones, 2 reintentos, 5 s |
| Plazo propio | Ninguno (lo pone la plataforma) | Ninguno |
| Topes | 250 000 descubiertos, 400 MB | Ninguno |

Se comparan **implementaciones tal como se entregan**, en el formato oficial (carrera simultánea). Las diferencias de concurrencia y HTTP impiden atribuir el resultado solo a la estrategia. La exportación `wiki_race_companion_dfs` (`6635188`, `Player.Coordinator`) es una versión de desarrollo anterior y **no participa**.

## Condiciones fijas

- Plataforma oficial `FLAGlab/wiki_race` `c414bb0` en Docker, con dos cambios locales (`platform/config/dev.exs` y `docker-compose.override.yml`; ver `wiki_race/competition/`).
- Snapshot `wikipedia_en_top_nopic.zim`, SHA-256 `b2806831e14690cbcafeb1b6e7bd4439fd59b3e5fbeaeb300a5792dece510ee0`.
- Límite de 120 s y sondeo de 250 ms (fijos en `Tournament.Server`). Verificador y puntuación oficiales.
- Resultados en `wiki_race/platform/priv/data/competition-2026-11/results.terms`. El `results.terms` anterior (carrera 2) no se toca: si se usara, adelantaría el calendario una ronda.

## Calendario (`schedule.exs`, igual a `round_pairs` de `dev.exs`)

| Rondas | Bloque | player1 | player2 | Pares |
|---|---|---|---|---|
| 1 | humo (excluida) | Reciprocity | Exploradores | Tiger → Antarctica |
| 2-12 | A | Reciprocity | Exploradores | Los 11 pares oficiales, permutación con semilla 4218 |
| 13-23 | B | Exploradores | Reciprocity | Orden inverso del bloque A |

Orden del bloque A: Whisk → Shoehorn, Bird → Nelson Mandela, Tiger → Antarctica, Enzyme → Hong Kong, Old Trafford → Virus, Maya civilization → Protein, Solar eclipse → Spanish language, Leopard → YouTube, Raccoon → Elizabeth II, Dinosaur → Video game, Antarctica → The Beatles. Por la inversión, Antarctica → The Beatles se corre dos veces seguidas (rondas 12 y 13).

`verify_schedule.exs` comprueba el calendario con el código real del torneo, incluidos reinicios tras las rondas 5 y 12.

## Procedimiento

Antes de la ronda 1:

1. Fijar en `manifest.exs` el commit de Reciprocity que se va a ejecutar.
2. `elixir verify_schedule.exs` (desde este directorio): debe terminar con "Calendario verificado".
3. Override activo = bloque A (`wiki_race/competition/docker-compose.override.block-A.yml`).
4. Desde `wiki_race/`: `docker compose up -d`. La plataforma se recrea con el cambio de `dev.exs` y del directorio de resultados.
5. Esperar `connected to platform@platform` en los logs de player1 y player2 (Reciprocity compila por primera vez en OTP 28).
6. En `/admin`: ronda 1 de 23, par Tiger → Antarctica, ambos nodos conectados. **No usar el selector de par.**

Cada ronda:

1. Comprobar en `/admin` que la ronda y el par son los del calendario y que ambos nodos están conectados.
2. Iniciar la carrera y esperar a que termine. Si una ronda falla (nodo caído, error de arranque), **cuenta igual** y no se repite: anotarlo.
3. Tras la ronda 1: comprobar que hay un resultado y una línea `event=race_end` de Reciprocity. Si falla, parar.

Cambio de bloque (tras la ronda 12):

1. **Guardar los logs del bloque A antes de recrear contenedores** (se pierden al recrearlos): `mkdir -p ../wiki_race_reciprocity/experiments/competition/logs` y `docker compose logs --no-color --tail=300 platform player1 player2 > ../wiki_race_reciprocity/experiments/competition/logs/block-a.log`. Comprobar que contiene 12 líneas `event=race_start` (humo + bloque A); con `--tail=300` por servicio no debería truncarse, pero si faltan, repetir con un `--tail` mayor.
2. `cp competition/docker-compose.override.block-B.yml docker-compose.override.yml` y `docker compose up -d`. Solo se recrean player1 y player2: la sección `platform` es idéntica en A y B.
3. Esperar la reconexión de ambos nodos y comprobar en `/admin` la ronda 13 y Antarctica → The Beatles.

Al terminar: guardar `logs/block-b.log` igual y ejecutar
`elixir decode_results.exs --logs logs/block-a.log --logs logs/block-b.log --out results.csv`.

## Clasificación (`decode_results.exs`)

| outcome | grupo | Criterio |
|---|---|---|
| `found` | válido | Ruta verificada por la plataforma |
| `exhausted` | válido | Reciprocity: `end_reason=exhausted` en su log. Exploradores: `:exhausted` (BFS principal agotado) con descargas |
| `censored_time_limit` | censurado | Sin ruta al cumplirse los 120 s (estado `:running`) |
| `censored_resource_limit` | censurado | Reciprocity: un límite rechazó enlaces (`end_reason=resource_limit`) |
| `censored_deadline` | censurado | Reciprocity con plazo propio (no debería ocurrir) |
| `rejected` | fallo | La plataforma rechazó una ruta (-1.0) |
| `operational_failure` | fallo | `:down`/`:error`, `no_workers`, o Exploradores agotado sin descargas |
| `unclassified` | fallo | Faltan datos (p. ej. log de Reciprocity no capturado) |

Solo la ronda 1 se excluye (`analyzed=false`). Cada fila lleva ronda, bloque, par, implementación, slot, commits, snapshot y el resultado oficial completo.

## Métricas y análisis

Por implementación y ronda: resultado, `path_length`, `elapsed_ms`, `first_elapsed_ms`, `visited_count` (descargas correctas según el propio crawler), `score`, `utilization`; para Reciprocity además `pages`, `discovered` y `end_reason` del log.

Análisis descriptivo y pareado por par (22 observaciones, 2 por par): éxitos de cada uno, prueba de signo sobre los pares donde solo uno encuentra ruta, medianas de `elapsed_ms` y `visited_count` cuando ambos encuentran, diferencia de `path_length`, suma de puntuaciones y comparación entre bloques (efecto del slot).

## Limitaciones

- Concurrencia 16 frente a 32 y Kiwix compartido: la carrera simultánea favorece a quien pide más.
- Exploradores es aleatorio sin semilla: sus repeticiones varían también por diseño.
- Caché caliente entre repeticiones; Tiger → Antarctica se corre tres veces (humo incluido).
- `visited_count` **no es comparable** y queda fuera de las conclusiones: Reciprocity cuenta también el probe y los candidatos; Exploradores cuenta una vez cada URL descargada (compartida entre BFS y exploradores), sin reintentos ni redirecciones.
- Pares cortos (< 1 s): el ruido entre ejecuciones puede ser del orden de las diferencias.
- Una ronda fallida no se repite: reduce n.
