# Auditoría comparativa de las tres implementaciones

Fecha: 2026-11-09. Auditoría de solo lectura: no se modificó código, ramas, worktrees ni infraestructura, y no se ejecutaron carreras.

| Implementación | Ubicación | Commit / estado |
|---|---|---|
| `feature/reciprocity` (nuestra) | `wiki_race_reciprocity/player/` | Sobre `c414bb0`, con cambios sin commit tras la refactorización |
| `feature/bfs-explorers` | `wiki_race_companion/player/` | `02d333e` |
| `feature/dfs-crawler` | `wiki_race_companion_dfs/player/` (exportación de `player/`) | `6635188` |

Evidencia: **[C]** leído en el código, **[M]** medido en ejecución real (solo las dos carreras de `docs/entorno-wiki-race.md`), **[H]** hipótesis sin medir.

## 1. Resumen ejecutivo

- **Menos código de producción:** `dfs-crawler`, con 342 líneas alcanzables en carrera (468 en total en `lib/player`). Le siguen nuestra implementación (624) y `bfs-explorers` (782).
- **Algoritmo real [C]:** `dfs-crawler` es un **BFS por niveles con barrera**. `Player.DFS` existe pero no participa en la competición. `bfs-explorers` es un BFS por niveles con 24 exploradores aleatorios. La nuestra es un BFS asíncrono sin barrera, con dos variantes opcionales: best-first y frontera inversa.
- **Menor complejidad conceptual:** `dfs-crawler`. Un `GenServer`, una cola por nivel y una descarga por `Task`.
- **Lo que no admite discusión:** las dos implementaciones del compañero **han corrido** y encontrado caminos aceptados [M: `bfs-explorers` en las dos carreras, `dfs-crawler` en la segunda]. **La nuestra nunca se ha compilado.** Ninguna de sus ventajas está demostrada.
- **Mejor equilibrio hoy:** `dfs-crawler` como base segura. La nuestra solo pasa a ser la mejor opción si compila, pasa sus pruebas y E4 muestra ventaja. No se ha demostrado nada de eso.

## 2. Metodología de conteo

Análisis textual con Python, sin parser de Elixir.

| Concepto | Regla |
|---|---|
| Código | Líneas no vacías, fuera de heredocs `"""` y que no empiezan por `#` |
| Función | `def` o `defp` a 2 espacios de sangría; las cláusulas del mismo nombre y módulo cuentan como una función |
| Fin de función | Con `do` al final de la cabecera, la primera línea `  end`; con `do:`, cuando la sangría vuelve a 2 o menos |
| Complejidad estimada | 1 por cláusula + `if`/`unless` + brazos `->` + `and`/`or`/`&&`/`\|\|` + `when`. Aproximación de la complejidad ciclomática |
| Anidamiento | (sangría máxima de código de la función − 4) / 2. Las líneas de continuación alineadas a mano lo inflan |
| Producción | `player/lib/player/**/*.ex`. El contrato `lib/wiki_race/` (43 líneas) es idéntico en las tres y se informa aparte |
| Alcanzable en carrera | Módulos a los que se llega desde `Player.Crawler` y `Player.Application`. Solo afecta a `dfs-crawler` |
| Pruebas | `player/test/player/*.exs` y `test/support/`; se excluye el `contract_test.exs` oficial, común a las tres |

## 3. Código de producción

| Medida | Nuestra | `bfs-explorers` | `dfs-crawler` (todo) | `dfs-crawler` (alcanzable) |
|---|---|---|---|---|
| **Líneas de código** | **624** | **782** | 468 | **342** |
| Módulos | 12 | 6 | 8 (+1 archivo solo con comentarios) | 4 |
| Funciones (públicas) | 81 (44) | 61 (22) | 38 (17) | 29 (11) |
| Cláusulas | 107 | 97 | 63 | 49 |
| `if` / `case` / `cond` / `with` | 15 / 9 / 2 / 4 | 26 / 21 / 5 / 6 | 10 / 8 / 3 / 9 | 7 / 7 / 1 / 6 |
| Funciones con varias cláusulas | 18 | 21 | 16 | 13 |
| Complejidad media / máxima estimada | 2,25 / 8 | 4,02 / 17 | 3,66 / 11 | 3,41 / 11 |
| Longitud media de función | 6,1 | 11,2 | 10,5 | 9,9 |
| Funciones de 25 o más líneas | 1 | 5 | 3 | 2 |
| Funciones con anidamiento ≥ 3 | 2 | 14 | 6 | 4 |

### Por archivo

| Nuestra | Líneas | `bfs-explorers` | Líneas | `dfs-crawler` | Líneas |
|---|---|---|---|---|---|
| `race.ex` | 229 | `explorer_coordinator.ex` | 384 | `wikipedia.ex` | 169 |
| `links.ex` | 80 | `wikipedia.ex` | 169 | `coordinator.ex` | 126 |
| `fetcher.ex` | 78 | `explorer.ex` | 138 | `crawler.ex` | 37 |
| `frontier.ex` | 72 | `crawler.ex` | 40 | `application.ex` | 10 |
| `reverse.ex` | 58 | `status_store.ex` | 40 | `bfs.ex` (no alcanzable) | 45 |
| `status_table.ex` | 38 | `application.ex` | 11 | `dfs.ex` (no alcanzable) | 45 |
| `route.ex` | 24 | | | `ejemplos.ex` (no alcanzable) | 36 |
| `stats.ex` | 18 | | | `heuristic.ex` (solo comentarios) | 0 |
| `crawler.ex` | 16 | | | | |
| `application.ex` | 11 | | | | |

### Funciones más complejas

| Implementación | Función | Complejidad estimada | Líneas |
|---|---|---|---|
| `bfs-explorers` | `Explorer.receive_result/4` | 17 | 46 |
| `bfs-explorers` | `ExplorerCoordinator.siguiente_trabajo/1`, `entregar/4`, `preparar_exploradores/1` | 11 | 20–33 |
| `dfs-crawler` | `Coordinator.handle_info/2`, `despachar/1` | 11 | 25 |
| Nuestra | `Reverse.next/3` | 8 | 12 |
| Nuestra | `Race.handle_info/2` | 7 | 15 |
| Nuestra | `Race.init/1` (la más larga) | 5 | 51 |

### Dependencias, configuración y mecanismos

| Aspecto | Nuestra | `bfs-explorers` | `dfs-crawler` |
|---|---|---|---|
| `mix.exs`, `mix.lock`, `Dockerfile` | Iguales a la plantilla | Iguales | Iguales (`.formatter.exs` cambiado) |
| Directorio `config/` | No | No | No |
| Procesos por carrera | `Race` + `DynamicSupervisor` + 16 `Fetcher` (GenServer) | `ExplorerCoordinator` + `Task` por descarga (hasta 32) | `Coordinator` + `Task` por descarga (hasta 8) |
| Procesos de aplicación | `StatusTable` y `RaceSup` | `StatusStore` y `DynamicSupervisor` | `DynamicSupervisor` |
| ETS | `seen`, `goals` y la tabla de estado | Caché de vecinos y tabla de estado | Ninguna |
| Otros | `:atomics` (límites) y `:counters` (estadísticas) | — | — |
| `Task` | No | Sí | Sí |

`Task` no está prohibido, pero tampoco figura en la lista OTP del README oficial.

## 4. Pruebas (no se suman a producción)

| Medida | Nuestra | `bfs-explorers` | `dfs-crawler` |
|---|---|---|---|
| Líneas de código de pruebas | 544 | 1 232 | 745 |
| Casos de prueba | 52 | 45 | 40 |
| Servidor simulado | Adaptador de Req en memoria | Servidor HTTP local en el test | Servidor HTTP local en el test |
| ¿Se han ejecutado? | **No** | Sin constancia en este workspace | Sin constancia en este workspace |

El tamaño de las pruebas no indica la extensión de la implementación.

## 5. Documentación y archivos auxiliares (fuera de la entrega)

| Implementación | Contenido |
|---|---|
| Nuestra | `experiments/reciprocity/`: 621 líneas en documentos Markdown, 754 en scripts (`run_experiment.py`, `analyze_extra.py`, `e4_runner.exs`) y datos de E2 |
| `bfs-explorers` | Ninguno fuera de la plantilla |
| `dfs-crawler` | `player/examples/` (90 líneas de scripts de práctica). Están **dentro** de `player/` pero fuera de `lib/` |

## 6. Evaluación arquitectónica y algorítmica

| Criterio | Nuestra | `bfs-explorers` | `dfs-crawler` |
|---|---|---|---|
| Algoritmo | BFS asíncrono; best-first opcional; inversa opcional con activación adaptativa | BFS por niveles y exploradores aleatorios, con mejora del camino tras el primero | BFS por niveles con barrera |
| Simplicidad | Media: 4 componentes con estado y 6 puros | Baja: coordinador de 384 líneas con dos tipos de búsqueda y caché compartida | Alta |
| Separación de responsabilidades | Buena: extracción, caminos y fronteras son puros. `race.ex` concentra el 37 % | Baja: un módulo gestiona BFS, exploradores, caché, tareas y estado | Buena para su tamaño |
| Idiomaticidad | Cláusulas y pattern matching en resultados, fronteras e inversa; pocos condicionales anidados | Muchos `cond`/`case` anidados (14 funciones con anidamiento ≥ 3) | Correcta y directa |
| Concurrencia | Reclamación atómica en ETS desde los Fetchers; el coordinador no descarga ni parsea | El coordinador recibe listas completas de vecinos; comparte descargas entre búsquedas | El coordinador recibe todo; la barrera deja cupos ociosos |
| Memoria | Tope de descubiertos y corte por memoria (solo frena el descubrimiento) | Sin límite: `padres` y caché de vecinos en ETS | Sin límite: `padres` y colas |
| Errores | Excepción → caída del Fetcher, registro de OTP y reposición. Sin reintentos | Hasta 2 reintentos con espera en errores transitorios | Igual que `bfs-explorers` |
| Terminación | Un reporte; cancela descargas; termina sin workers; no reporta tras 114 s | Varios reportes; sigue cargando Kiwix mientras se verifica | Un reporte; cancela descargas |
| `status/1` | Lectura de ETS | Lectura de ETS | `GenServer.call` con 200 ms: puede fallar con el buzón ocupado |
| Reconstrucción de caminos | Padres en ETS y `Route.validate/3` antes de reportar | Padres por búsqueda; caminos de exploradores con prefijo y bloqueo de repetidos | Padres en mapa |
| Compatibilidad con el verificador | Misma resolución y redirecciones que el verificador | `redirect: false` (no usa redirecciones: conservador). `String.trim(href)`, que el verificador no hace | Igual que `bfs-explorers` |
| Riesgo de rechazo | [H] Bajo por diseño, sin ejecutar | Bajo en lo observado [M]; más reportes implican más exposición | Bajo en lo observado [M] |
| Potencial competitivo | [H] El más alto en teoría (inversa en pares largos); sin medir | [H] Medio; los exploradores generan caminos largos | [H] Bajo-medio: 8 descargas y barrera |

### Capacidades implementadas frente a validadas

| Capacidad | Nuestra | `bfs-explorers` | `dfs-crawler` |
|---|---|---|---|
| Compila | No demostrado | Sí [M] | Sí [M] |
| Camino aceptado en carrera real | No | Sí, Tiger → Antarctica, 2 hops, en 3 ejecuciones (2 carreras) [M] | Sí, Tiger → Antarctica, 2 hops, en 1 ejecución [M] |
| Pares de 3 o más saltos | No medido | No medido | No medido |
| Memoria en `all` y 512 MB | No medida | No medida | No medida |

## 7. Hallazgos por implementación

### Nuestra (`feature/reciprocity`)

| Gravedad | Hallazgo |
|---|---|
| **Crítico** | No compilada ni ejecutada: cualquier error impide competir |
| Alto | `race.ex` (229 líneas) concentra el 37 % del código; `Race.init/1` tiene 51 líneas |
| Medio | `Stats` (18 líneas y unas 12 llamadas) solo sirve para E4 y no aporta en el torneo |
| Medio | `Frontier.BestFirst` (unas 50 líneas) no tiene ninguna evidencia a favor |
| Medio | Sin reintentos: un fallo transitorio pierde la URL. Las referencias reintentan |
| Medio | El límite de memoria no libera memoria |
| Bajo | La reposición de workers (`max_replacements`) y `:hibernate` añaden lógica cuyo beneficio no está medido |

### `bfs-explorers`

| Gravedad | Hallazgo |
|---|---|
| Alto | Memoria sin límite: caché ETS de listas de vecinos y padres |
| Alto | Complejidad concentrada: `explorer_coordinator.ex` (384 líneas) y `Explorer.receive_result/4` (complejidad 17, 46 líneas) |
| Medio | Varios reportes y BFS activo durante la verificación: más carga en Kiwix y más exposición al plazo de gracia de 5 s |
| Medio | `String.trim(href)` puede producir enlaces que el verificador no reconoce |
| Bajo | Usa `Task`, que no figura en la lista OTP |

### `dfs-crawler`

| Gravedad | Hallazgo |
|---|---|
| Alto | Memoria sin límite |
| Medio | `status/1` mediante `GenServer.call` con 200 ms |
| Medio | La barrera de nivel y 8 descargas limitan el rendimiento [H] |
| Medio | 126 líneas de código no alcanzable (`bfs.ex`, `dfs.ex`, `ejemplos.ex`), un archivo solo con comentarios y `examples/` dentro de `player/` |
| Medio | `String.trim(href)` |
| Bajo | Usa `Task` |

## 8. Juicio crítico

**¿Cuál tiene menos código de producción?** `dfs-crawler`: 342 líneas alcanzables y 468 en total. La nuestra tiene 624 y `bfs-explorers` 782.

**¿Cuál tiene menor complejidad conceptual?** `dfs-crawler`: un coordinador, una cola por nivel, sin ETS y sin estrategias alternativas. Por complejidad estimada por función, la nuestra es la más baja (media 2,25, máxima 8), pero tiene más piezas.

**Complejidad que añadimos frente a `dfs-crawler`** (+282 líneas alcanzables):

| Componente | Líneas aprox. | Ventaja que lo justifica | Estado |
|---|---|---|---|
| Fetchers GenServer bajo un supervisor | ~78 | Sin `Task`; parseo fuera del coordinador | Ventaja de cumplimiento; rendimiento sin medir |
| `StatusTable` | ~38 | `status/1` no bloquea | Evita el riesgo de `GenServer.call` |
| Tope de memoria con `:atomics` | ~10 | Reduce el riesgo de `halt` | Sin medir |
| Reclamación con `insert_new` | Dentro de `fetcher.ex` | Deduplicación sin coordinador | Sin medir |
| BFS sin barrera | Dentro de `race.ex` | Cupos siempre ocupados | Sin medir |
| `Reverse` y `goals` | ~90 | Encuentro a medio camino; indicios en E2 | Sin medir |
| `Frontier.BestFirst` | ~50 | Ninguna demostrada | Sin evidencia |
| `Stats` | ~30 | Solo E4 | No aporta al torneo |
| `Route.validate/3` y plazo de 114 s | ~15 | Evitan −1,0 | Justificados por las reglas |

**Frente a `bfs-explorers`:** tenemos 158 líneas menos, menos condicionales (15 `if` frente a 26) y ninguna función con complejidad mayor que 8. A cambio, añadimos frontera inversa, best-first y `Stats`, y no tenemos ni los exploradores ni la caché de vecinos ni la mejora tras el primer camino.

**¿Qué sigue siendo innecesario en la nuestra?**
- `Stats` en la versión de entrega, salvo que se use en E4.
- `Frontier.BestFirst`, mientras no haya evidencia.
- La reposición configurable de workers. Con un fallo, bastaría terminar el trabajo afectado.
- `:hibernate`, mientras no se mida.

Eliminar `Stats` y `BestFirst` dejaría unas 540 líneas.

**Mejor equilibrio hoy:** `dfs-crawler`, porque es la más pequeña, sencilla y ya validada en una carrera, aunque tiene memoria sin límite y `status/1` frágil. La nuestra puede ser la mejor, pero hoy no lo es: le falta la validación más básica.

## 9. Ranking razonado

| Criterio | 1.º | 2.º | 3.º |
|---|---|---|---|
| Menos código de producción | `dfs-crawler` (342) | Nuestra (624) | `bfs-explorers` (782) |
| Mantenibilidad | `dfs-crawler` (tras eliminar su código muerto) | Nuestra (complejidad baja por función, más piezas) | `bfs-explorers` (funciones largas y anidadas) |
| Fiabilidad demostrada | `bfs-explorers` (3 ejecuciones) | `dfs-crawler` (1 ejecución) | Nuestra (sin compilar) |
| Potencial competitivo teórico [H] | Nuestra (inversa y sin barrera) | `bfs-explorers` | `dfs-crawler` |

## 10. Recomendaciones priorizadas

1. **Compilar y ejecutar las pruebas de nuestra implementación.** Sin eso, ninguna comparación de calidad es relevante para la entrega.
2. **Mientras tanto, considerar `dfs-crawler` como base de emergencia**, tras eliminar `bfs.ex`, `dfs.ex`, `ejemplos.ex`, `heuristic.ex` y `examples/`. Corregir antes `status/1` (leer de ETS) y añadir un tope de memoria, cambios pequeños.
3. **Reducir la nuestra antes de entregarla:** quitar `Stats` de la versión del torneo y eliminar `BestFirst` si E4 no muestra ventaja.
4. **Incorporar a la nuestra un reintento** ante errores transitorios, como las referencias, con un único reintento.
5. **Ejecutar E4** con las tres estrategias y las dos referencias en pares de 3 o más saltos. Es la única forma de justificar la frontera inversa.
6. **No adoptar `String.trim(href)`** en ninguna implementación: diverge del verificador.
