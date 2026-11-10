# E4: protocolo de comparación de políticas

**Estado: diseñado y sin ejecutar.** Ver `e4-summary.md`.

## Condiciones comunes

| Elemento | Valor |
|---|---|
| Estrategias | `:bfs`, `:best_first` y `:reverse` (opción `strategy:` de `Crawler.start/3`) |
| Infraestructura | La misma: `Race`, `Fetcher`, `Links`, `Route` y `Stats` |
| Concurrencia y HTTP | Valores por defecto de `Player.Race` en las tres (16 workers, 5 s de timeout) |
| Dataset | `wikipedia_en_top_nopic` |
| Pares | Seis del pool público del curso, en `e4_runner.exs` |
| Repeticiones | 10 por par y política, con orden aleatorio intercalado y semilla 4218 |
| Límite | 120 s por ejecución |
| Recursos | 512 MB y 1 CPU por contenedor del banco |

## Métricas (`e4-results.csv`)

Estado final, longitud del camino, páginas, errores, duplicados, tiempo total de descarga, descubiertos, memoria máxima, tiempo al primer camino, encuentros, y candidatos examinados y confirmados. Latencia: solo la media (tiempo total de descarga / páginas); se eliminaron los percentiles para reducir código.

Métrica principal: **mediana del tiempo al primer camino válido**, con cero caminos rechazados. Ninguna política se declara ganadora con una sola ejecución.

## Limitaciones del banco

- **Reportes rechazados:** el banco no pasa por el verificador oficial. Solo se puede medir con carreras en la plataforma.
- **Sin rival:** cada ejecución corre sola. No representa dos crawlers compartiendo Kiwix.
- **Kiwix compartido:** usa el servicio ya en marcha, que no debe reiniciarse.
- **Caché:** el orden aleatorio reduce el sesgo de caché, pero no lo elimina.
- **Datos experimentales:** no se deben incorporar al crawler.

## Ejecución

Requiere un contenedor efímero con acceso solo a la red de Kiwix, además del montaje de `experiments/`:

```sh
docker run --rm --network wiki_race_default --memory 512m --cpus 1 -e MIX_ENV=dev \
  -v <worktree>/player:/app -v <worktree>/experiments/reciprocity:/e4 \
  -v /app/_build -v /app/deps wikirace-player \
  mix run /e4/e4_runner.exs /e4/e4-results.csv
```

La red `wiki_race_default` es la del Compose existente; no se modifica.
