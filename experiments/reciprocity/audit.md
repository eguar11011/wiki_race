# Auditoría técnica de la tercera implementación (tras la refactorización)

Fecha: 2026-11-09. Alcance: `wiki_race_reciprocity/player/`, en la rama `feature/reciprocity`, sin commits. La versión anterior se conserva en la copia temporal de la sesión y se resume en el apartado 4.

Clasificación: **Crítico**, **Alto**, **Medio** y **Bajo**. Evidencia: **[C]** confirmado leyendo el código, **[R]** riesgo potencial, **[H]** hipótesis que requiere medición.

## 1. Resumen ejecutivo

- **El código sigue sin compilarse ni ejecutarse.** Se repitió el intento el 2026-11-09 y el sandbox lo bloquea igual: `open ~/.docker/config.json: operation not permitted` y no hay socket de Docker. Tampoco hay Elixir local. Nada de este documento demuestra que el código funcione.
- **Se redujo el tamaño en un 34 %:** de 951 a 624 líneas de código de producción, de 14 a 12 módulos y de 95 a 76 funciones. Ahora es más pequeño que `bfs-explorers` (782) y mayor que `dfs-crawler` (468).
- **Se corrigieron los hallazgos estructurales:**
  - Las métricas ya no controlan la búsqueda.
  - No hay excepciones silenciadas.
  - Las redirecciones son las de Req, igual que el verificador.
  - Se eliminaron `Config`, `Http`, `Metrics` y la abstracción `Policy`.
  - La estrategia inversa es un módulo puro explícito.
  - Los enlaces de S que también enlaza el objetivo vuelven a tener prioridad.
  - Las pruebas del extractor usan valores esperados escritos a mano.
- **Siguen abiertos:** liberar memoria al superar el límite, reintentar un fallo transitorio, evitar descargas duplicadas de candidatos y, sobre todo, compilar y medir.

## 2. Comparación con las implementaciones de referencia

Mismo script de análisis textual para las tres. "Código" excluye docstrings, comentarios y líneas en blanco.

| Medida | `bfs-explorers` (`02d333e`) | `dfs-crawler` (`6635188`) | Tercera (refactorizada) |
|---|---|---|---|
| Producción: líneas totales / código | 1 041 / 782 | 681 / 468 | 891 / 624 |
| Pruebas: líneas totales / código | 1 577 / 1 234 | 968 / 746 | 663 / 546 |
| Casos de prueba propios | 45 | 40 | 52 |
| Documentación propia | README de plantilla | README de plantilla | `experiments/reciprocity/` (diseño, auditoría y experimentos) |
| Archivos en `lib/player` | 6 | 8 (incluye `dfs.ex`, `bfs.ex` y `ejemplos.ex`, fuera del flujo de competición) | 10 |
| Probado en carreras reales | Sí | Sí | **No; ni compilado** |

`dfs-crawler` no ejecuta DFS: su flujo de competición es un BFS por niveles en `Player.Coordinator`. Parte de su código (`dfs.ex`, `bfs.ex`, `ejemplos.ex`) no participa en las carreras.

### Arquitectura y mecanismos

| Aspecto | `bfs-explorers` | `dfs-crawler` | Tercera |
|---|---|---|---|
| Búsqueda | BFS por niveles y 24 exploradores aleatorios | BFS por niveles con barrera | BFS sin barrera, best-first o BFS con frontera inversa |
| Concurrencia | `Task.async` (32) desde un GenServer | `Task.async` (8) desde un GenServer | GenServers Fetcher (16) bajo un `DynamicSupervisor` enlazado |
| Deduplicación | Mapa en el coordinador y caché ETS | Mapa en el coordinador | `:ets.insert_new` en cada Fetcher, sin pasar por el coordinador |
| `status/1` | Lectura de ETS | `GenServer.call` con 200 ms | Lectura de ETS |
| Memoria | Sin límite | Sin límite | Tope de descubiertos y corte por memoria |
| Tras el primer camino | Sigue el BFS principal y puede volver a reportar | Se detiene | Se detiene; un solo reporte |
| Plazo propio | No | No | No reporta tras 114 s |
| Uso del objetivo | Solo comprueba si se llega | Solo comprueba si se llega | Título (best-first) y enlaces confirmados (inversa) |

### Justificación de cada componente adicional

| Componente | Líneas de código | Capacidad frente a las referencias | Ventaja | Cómo medirla |
|---|---|---|---|---|
| Fetchers GenServer en lugar de `Task` | 78 (`fetcher.ex`) | Cumple la lista OTP sin depender de que `Task` se acepte | Cumplimiento | — |
| `insert_new` en Fetchers | Dentro de `fetcher.ex` | Deduplicación sin mensajes al coordinador | [H] Menor carga del coordinador | Tiempo de cola en `Race` |
| Tope de memoria con `:atomics` | Unas 6 | Frena el descubrimiento al acercarse al límite | Reduce el riesgo de `halt` | E4: memoria máxima en `all` |
| `Player.Reverse` y tabla `goals` | 58 + unas 30 en `race.ex` | Encuentro a medio camino | [H] Basado en E2 (CONDITIONAL GO) | E4: tiempo al primer camino en pares de 3 saltos |
| `Frontier.BestFirst` | Unas 50 | Prioridad por título, posición y profundidad | [H] Sin evidencia todavía | E4 |
| `Route.validate/3` | 11 | Comprobación antes de reportar | Evita −1,0 por error propio | Pruebas |
| `Stats` y `StatusTable.publish_stats/2` | 18 + 2 | Resumen por carrera | Necesario para E4 | — |
| Plazo de 114 s | 2 | No reportar cuando la verificación no tendría tiempo | Evita −1,0 por verificación tardía | — |

Si E4 no muestra ventaja para `BestFirst` o `Reverse`, se deben eliminar.

## 3. Métricas antes y después

| Medida | Antes | Después |
|---|---|---|
| Producción: líneas totales / código | 1 272 / 951 | 891 / 624 |
| Módulos / archivos | 14 / 14 | 12 / 10 |
| Funciones distintas (públicas) | 95 (54) | 76 (42) |
| Funciones con varias cláusulas | 16 | 19 |
| `if` / `case` / `cond` / `with` | 20 / 23 / 3 / 3 | 15 / 9 / 2 / 4 |
| Complejidad media estimada | 3,13 | 2,61 |
| Complejidad máxima estimada | 26 (`Search.handle_info/2`) | 10 (`Fetcher.claim/3`) |
| Coordinador: código / complejidad de `handle_info/2` | `search.ex` 247 / 26 | `race.ex` 229 / 8 |
| Configuración | `Config`, 16 claves | `@defaults` de `Race`, 10 claves |
| Métricas | 23 contadores y 48 cubetas | 9 contadores |
| Pruebas: líneas de código / casos | 629 / 54 | 546 / 52 |

La complejidad es una estimación textual sin parser. Con funciones de varias líneas y guardas (`replace_worker/1`), el recuento de líneas por función tiene errores.

## 4. Hallazgos: corregidos y pendientes

| ID | Hallazgo original | Estado | Cómo |
|---|---|---|---|
| A1 | `Player.Policy` no aislaba la estrategia inversa | **Corregido** | `Player.Frontier` solo ordena (4 funciones, sin no-ops). La inversa es `Player.Reverse`, puro, y se integra mediante la tabla `goals`: un destino es "algo desde lo que se conoce el resto del camino". Detectar el objetivo y detectar un encuentro son el mismo mecanismo |
| A2 | `Search` concentraba demasiado | **Parcial** | `Race.handle_info/2` pasa de complejidad 26 a 8, y la lógica inversa sale a `Reverse`. `race.ex` sigue teniendo el 37 % del código |
| A3 | `Http` reimplementaba redirecciones | **Corregido** | Módulo eliminado. `Req.get/2` con redirecciones por defecto y `retry: false`, como el verificador |
| A4 | `Metrics` sobredimensionado | **Corregido** | `Stats`, con 9 contadores; sin histogramas |
| A5 | Métricas como control | **Corregido** | `:atomics` propios en el contexto (descubiertos y memoria). `Stats` no se lee en ninguna decisión |
| A6 | `Config` con claves muertas | **Corregido** | Eliminado; `@defaults` en `Race`. Los parámetros de `Reverse` y `BestFirst` son atributos de módulo |
| A7 | Funciones solo para pruebas | **Parcial** | Eliminado `canonical_set/2`; se mantienen `Crawler.start/3` y `Crawler.stats/1`, necesarias para E4 |
| I2 | Triplicación de colas en `Reverse` | **Corregido** | `Reverse` usa una sola lista de pendientes |
| I3 | `if` anidados en `Fetcher` | **Corregido** | `conclude/3` por cláusulas según el tipo; `run/2` con `with` |
| I4 | `rescue _` silencioso | **Corregido** | Sin `rescue` en `Fetcher`: una excepción hace caer el proceso, OTP la registra y `Race` lo repone |
| R4 | Carril prioritario que llegaba tarde | **Corregido** | `Reverse.probed/4` pone primero los candidatos ya alcanzados; confirmarlos cierra el camino sin más descargas |
| R6 | Solo se probaba el primer predecesor | **Corregido** | `suffixes/2` devuelve todos, del más corto al más largo, y `try_routes/3` los prueba en orden |
| R7 | Tokenización en el coordinador | **Corregido** | Se calcula en el Fetcher |
| R10 | Pruebas del extractor tautológicas | **Parcial** | 18 casos con valores esperados escritos a mano. Los casos límite que dependen de Mochiweb siguen comparándose con la copia del verificador, y así se indica |
| R11 | Resultados no reproducibles | **Corregido** | Candidatos en orden de documento, sin aleatoriedad |
| R12 | Esperar al plazo sin workers | **Corregido** | Si no queda nada en curso tras repartir, la carrera termina |
| R2 | Tope laxo por `write_concurrency` | **Mitigado** | `:atomics` sin `write_concurrency`. El tope puede superarse en como mucho tantos artículos como workers concurrentes [C] |
| R3 | El límite de memoria no libera | **Pendiente** | Solo frena el descubrimiento |
| R5 | Un fallo transitorio pierde la URL | **Pendiente** | Igual que el verificador, sin reintentos |
| R8 | Descargas duplicadas de candidatos | **Pendiente** | Un candidato ya descargado como artículo directo se vuelve a descargar |
| R9 | Destinos que son redirecciones | **Mitigado** | Tasa de confirmación baja implica abandono. No hay tratamiento específico |
| R13 | Pool de Finch adicional por `connect_options` | **Eliminado** | Ya no se pasa `connect_options` |
| R14 | `confirmed` sin vaciar | **Bajo** | `goals` no se vacía al terminar; como mucho 65 filas |

## 5. Complejidad eliminada y conservada

**Eliminada:**
- Los módulos `Config`, `Http`, `Metrics`, `Policy`, `Policy.Bfs`, `Policy.BestFirst`, `Policy.Reverse` y `Search` (sustituido por `Race`).
- El bucle de redirecciones, 14 contadores, las cubetas de latencia, el reescalado por apariciones de `BestFirst` (ventana de 8 y contador en `seen`), el límite artificial de longitud en `Route`, los callbacks `on_result/3` y los `rescue` en `Fetcher` y `StatusTable.publish/2`.

**Conservada, con justificación:**
- Un `DynamicSupervisor` por carrera: garantiza que matar el pid termina todos los Fetchers.
- `StatusTable` como GenServer: la tabla debe sobrevivir a cada carrera.
- `Route.validate/3`, aunque la reconstrucción ya es correcta por construcción: un −1,0 cuesta más que una comprobación.
- El plazo de 114 s.
- `:hibernate` en los Fetchers: libera memoria tras cada página, aunque su coste no está medido.

## 6. Ejemplos de la refactorización

**Destinos unificados** (`fetcher.ex`): el objetivo y los predecesores confirmados se buscan igual.

```elixir
defp suffixes(links, context) do
  links
  |> Enum.flat_map(fn {canon, _url} -> :ets.lookup(context.goals, canon) end)
  |> Enum.map(fn {_canon, suffix} -> suffix end)
  |> Enum.sort_by(&length/1)
end
```

**Resultados por cláusulas** (`race.ex`): `apply_result/3` distingue error, artículo directo, sondeo del objetivo y candidato por pattern matching, sin condicionales anidados.

**Control separado** (`fetcher.ex`):

```elixir
defp room?(%{limits: limits, max_discovered: max}),
  do: :atomics.get(limits, 1) < max and :atomics.get(limits, 2) == 0
```

## 7. Estado de validación

| Elemento | Ejecutado | Estático | Escrito sin ejecutar | Pendiente externo |
|---|---|---|---|---|
| Compilación | | Bloques balanceados en todos los archivos | ✓ | Elixir 1.20 / OTP 28 |
| 52 casos de prueba más los 2 del contrato oficial | | | ✓ | Contenedor |
| Equivalencia del extractor | | 18 valores esperados revisados a mano | ✓ | Kiwix real y verificador |
| Sin `Task`/`Agent`, `/search`, `/suggest`, `Node.start`, `System.halt` ni `String.to_atom` | | ✓ | | |
| `mix.exs`, `mix.lock`, `lib/wiki_race/`, `Dockerfile`, `.formatter.exs` y `.gitignore` sin cambios | | ✓ (Git) | | |
| Un solo `@behaviour WikiRace.Crawler` | | ✓ | | |
| Sin referencias a los módulos eliminados | | ✓ | | |
| `MIX_ENV=prod mix release` | | | ✓ | Contenedor |
| E4 | | | ✓ (`e4_runner.exs` actualizado) | Contenedor y Kiwix |

Reproducción y resultados de los intentos de ejecución: ver `e4-summary.md`.

## 8. Riesgos restantes

| # | Gravedad | Riesgo |
|---|---|---|
| 1 | **Crítico** | Código nunca compilado: probables errores de compilación o de lógica sin detectar |
| 2 | Alto | [H] Memoria en 512 MB: sin liberación y sin medición |
| 3 | Alto | [H] Ninguna estrategia está medida; `BestFirst` y `Reverse` podrían no aportar nada |
| 4 | Medio | [R] Si Req convierte en `{:error, …}` una excepción del adaptador, la prueba "una excepción en una descarga no detiene la carrera" no ejercita la caída del worker. Hay otra prueba que mata el worker directamente |
| 5 | Medio | [C] `race.ex` sigue concentrando el 37 % del código |
| 6 | Medio | [C] R5 y R8 pendientes |
| 7 | Bajo | [H] El coste de hibernar tras cada página no está medido |

## 9. Evaluación global de mantenibilidad

**Media, frente a media-baja antes.** El código de producción es ahora menor que el de `bfs-explorers` y ofrece tres estrategias sobre una infraestructura realmente común. El ordenamiento usa un comportamiento de 4 funciones, la inversa es un módulo puro y los destinos se detectan con un único mecanismo. Pattern matching y cláusulas sustituyen a la mayoría de condicionales anidados.

Lo que impide valorarla más alto es que no se ha ejecutado nunca y que `race.ex` sigue siendo grande. La complejidad que añaden `BestFirst` y `Reverse` solo se justifica si E4 lo confirma.
