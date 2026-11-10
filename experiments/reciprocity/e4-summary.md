# E4: resumen

**No hay resultados.** E4 no se ha ejecutado y por eso no existe `e4-results.csv`. No se ha comparado ninguna política.

## Causa

Toda ejecución de Elixir o de Docker desde Claude Code está bloqueada:

| Intento | Error real |
|---|---|
| `docker run ... wikirace-player mix test` | `open ~/.docker/config.json: operation not permitted` y `dial unix /var/run/docker.sock: no such file or directory` |
| `mix`, `elixir` y `erl` | No existen en el entorno |
| Conexión a `127.0.0.1:8080` | `Operation not permitted` |

`docker run` no está en `sandbox.excludedCommands`, y esa lista está en un archivo protegido que Claude Code no puede editar. No se reutilizaron los comandos autorizados de `buildx bake` o `compose` para ejecutar otra cosa, porque esas excepciones se concedieron para un fin concreto.

## Lo que hace falta

Añadir manualmente el comando exacto de `e4-benchmark-design.md` a `sandbox.excludedCommands`, o ejecutarlo fuera del sandbox. Antes debe pasar la batería de pruebas.

## Evidencia previa

La única evidencia es `summary.md` (reciprocidad, CONDITIONAL GO), que no mide el rendimiento de ninguna política.
