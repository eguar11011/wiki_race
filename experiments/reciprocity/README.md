# Experimento de reciprocidad de enlaces

> **Solución competitiva (`feature/reciprocity`):** ver `architecture.md`. Pruebas, desde la raíz del workspace, sin red y con el perfil de 512 MB y 1 CPU:
>
> ```sh
> /Applications/Docker.app/Contents/Resources/bin/docker run --rm --network none --memory 512m --cpus 1 -e MIX_ENV=test -v "$PWD/wiki_race_reciprocity/player:/app" -v /app/_build -v /app/deps wikirace-player mix test
> ```

Mide si la reciprocidad local de Wikipedia es útil para la estrategia A de `docs/propuesta_tres_estrategias.md`. **Es una medición local para decidir un diseño: sus datos no deben incorporarse a ningún crawler** (regla de precálculo en `proyecto2/reglas_evaluacion.md`).

Etiquetas: **[H]** hecho en código o documentación, **[M]** medido aquí, **[I]** inferencia, **[P]** propuesta sin validar.

## Estado

- Script preparado y probado sin red con `selftest`.
- **La medición no se puede ejecutar dentro del sandbox** de Claude Code: la conexión a `127.0.0.1:8080` falla con `PermissionError: Operation not permitted`. Los contenedores están en marcha.
- Una ejecución en una Terminal normal genera `results.csv` y `run_metadata.json` en esta carpeta. `summary.md` se escribe también aquí, después del análisis.
- Ubicación: `wiki_race_companion/experiments/reciprocity/`. La carpeta `player/`, montada por `player1`, no se toca.
- **Estos archivos están en el árbol de trabajo sin seguimiento hasta que se haga commit en `feature/reciprocity`.** El checkout de `wiki_race_companion` sigue en `feature/bfs-explorers`, porque cambiarlo alteraría el código montado por `player1`.

## Hipótesis

Parte de los enlaces salientes de un destino T enlazan de vuelta a T. Esos artículos serían predecesores confirmados de T. **No es búsqueda inversa completa:** solo ve predecesores que además aparecen entre los enlaces salientes de T.

## Protocolo

| Paso | Detalle |
|---|---|
| Selección de destinos | Portada del snapshot → 12 enlaces al azar → 12 enlaces de cada uno → pool de hasta 90 artículos → destinos estratificados en tres tercios por grado de salida, 10 por tercio. Solo navegación local, sin conocimiento externo ni pares del torneo |
| Candidatos | Enlaces salientes de T sin repetidos y sin T; orden aleatorio con semilla; hasta 100 por destino |
| Reciprocidad | Descargar cada candidato y comprobar si `canonical(T)` está en sus enlaces |
| Búsqueda directa | Para 15 destinos, un origen S del pool; descargar S y hasta 80 enlaces suyos en orden del documento |
| Límites | 5 000 descargas, 6 000 peticiones HTTP (con redirecciones y reintentos), 1 500 s, concurrencia 1, pausa de 5 ms, timeout de 10 s |
| Destino | Solo `127.0.0.1:8080`; cualquier otra URL se rechaza antes de conectar |
| Reproducibilidad | Semilla 4218; el generador se reinicia por destino a partir de la semilla y del título |

**Justificación de los tamaños [I].** Con 100 candidatos, una tasa del 20 % tiene un error estándar de unos 4 puntos, suficiente para distinguir destinos con reciprocidad alta, media o baja. Con 30 destinos en tres estratos se puede ver dispersión sin recorrer el snapshot. El coste esperado es de unas 4 300 descargas secuenciales, en torno al tope fijado.

## Equivalencia con el verificador

| Aspecto | Verificador oficial [H] | Este script |
|---|---|---|
| Enlaces | `Floki.attribute("a", "href")`, parser Mochiweb | `html.parser` de Python, solo `<a href>` |
| Resolución | `URI.merge`, excluye `#`, `javascript:`, `mailto:` | `urljoin`, mismas exclusiones |
| Canónica | Ruta con `URI.decode`, sin `/` final, sin query ni fragmento | Misma regla con `unquote` |
| Redirecciones | Sigue redirecciones; base = URL pedida | Igual |

**No son idénticos**: Python y Mochiweb pueden diferir con HTML mal formado y `urljoin` no es `URI.merge`. Los resultados son una aproximación y no sustituyen al verificador. Adicionalmente se filtran espacios de nombres y recursos, con la lista de `wikipedia.ex`, que el verificador no filtra.

## Denominadores

- **Tasa por destino** = recíprocos / candidatos descargados con éxito de la **muestra**.
- **No se extrapola** al conjunto completo de enlaces de T. Los candidatos no examinados figuran en `results.csv` con `download_status=not_examined`.
- La tasa agregada se informa aparte de la distribución por destino.

## Comparación con BFS

Solo es una estimación en descargas, limitada a los primeros 80 enlaces de S. No se ejecutan carreras ni se modifican los jugadores. Costes:

| Medida | Descargas contadas |
|---|---|
| `bfs_2` | S y enlaces de S en orden del documento hasta el primero que enlaza a T |
| `prioridad_2` | T, S y enlaces de S con los que están en C primero |
| `encuentro_A` | T, S, candidatos examinados y enlaces de S hasta tocar un recíproco |

`encuentro_A` puede dar rutas de 2 o 3 saltos. Un BFS real de 3 saltos no se mide aquí.

## Limitaciones

- El pool se forma desde la portada: favorece artículos conectados.
- `top_nopic` no es `all`, el dataset de competencia.
- Mide descargas y latencia con un cliente único; no representa dos crawlers en carrera.
- Las rutas no se validan con el verificador oficial.

## Cómo reproducir

```sh
python3 run_experiment.py selftest   # sin red
python3 run_experiment.py run        # requiere acceso a 127.0.0.1:8080
python3 run_experiment.py analyze    # recalcula todos los indicadores
```

`run` no sobrescribe un `results.csv` existente.

## Columnas de `results.csv`

| Columna | Significado |
|---|---|
| `row_type` | `selection_main`, `selection_hub`, `selection_pool`, `target`, `candidate`, `source`, `forward` |
| `pair_id`, `target_id`, `candidate_id` | Identificadores |
| `target_title`, `candidate_title` | Títulos canónicos |
| `sample_seq` | Posición en el orden aleatorio |
| `document_index` | Posición en la página |
| `download_status` | `ok`, `http_error`, `empty`, `network_error:*`, `parse_error:*`, `not_examined` |
| `http_status`, `redirected`, `bytes`, `latency_ms`, `parse_ok`, `link_count`, `already_downloaded` | Datos de la descarga |
| `out_degree`, `candidates_sampled`, `tertile` | Datos del destino |
| `is_reciprocal` | El candidato enlaza a T (`forward`: el artículo es recíproco) |
| `in_target_links` | El artículo está entre los enlaces de T |
| `links_to_target` | Enlaza directamente a T |
| `reciprocal_links_hit` | Cuántos enlaces suyos son recíprocos confirmados |
