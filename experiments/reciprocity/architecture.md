# Arquitectura de `feature/reciprocity`

**Estado: código NUNCA COMPILADO NI EJECUTADO.** En el entorno de desarrollo no hubo Elixir ni Docker disponibles desde el sandbox (ver `e4-summary.md`).

## Algoritmo

- **Búsqueda principal:** BFS asíncrona, con cola FIFO sin barrera entre niveles (`Player.Frontier`).
- **Mecanismo auxiliar:** reciprocidad verificada (`Player.Reverse`), activa por defecto (`strategy: :reverse`). **No es una BFS bidireccional:** solo confirma, entre los enlaces del objetivo, cuáles enlazan de vuelta a él.
- **Encuentros:** la tabla `goals` relaciona cada artículo con el resto del camino desde él. Empieza con el objetivo y recibe cada predecesor confirmado. Una página que enlaza a una entrada de `goals` cierra un camino.
- **Reporte:** uno solo. Antes de reportar, `Route.validate/3` repite las comprobaciones estructurales del verificador. Después se cancelan las descargas en curso.

## Procesos

```
Player.Application (Supervisor)
├─ Player.StatusTable (GenServer, dueño de la tabla ETS de estados)
└─ Player.RaceSup (DynamicSupervisor)
   └─ Player.Race (GenServer, restart: :temporary)   ← pid que devuelve start/2
      └─ DynamicSupervisor enlazado
         └─ Player.Fetcher × 16 (GenServer, restart: :temporary, shutdown: :brutal_kill)
```

Sin `Task` ni `Agent`. `status/1` lee ETS directamente.

## Módulos

| Módulo | Responsabilidad |
|---|---|
| `Player.Crawler` | Contrato `start/2` y `status/1` |
| `Player.Race` | Reparto de trabajo, resultados, reporte y terminación |
| `Player.Fetcher` | Descarga (`Req`, `retry: false`, redirecciones por defecto), extracción y reclamación con `insert_new` |
| `Player.Links` | Extracción y canonicalización como `Verifier` |
| `Player.Route` | Reconstrucción y validación del camino |
| `Player.Frontier` | Cola FIFO |
| `Player.Reverse` | Reciprocidad verificada: activación, candidatos, turnos y abandono |
| `Player.StatusTable` | Estado y resumen por carrera |
| `Player.Stats` | Contadores para operación y validación |

## Parámetros (sin calibrar)

| Parámetro | Valor |
|---|---|
| Concurrencia, timeout | 16, 5 s |
| Tope de descubiertos, memoria | 250 000, 400 MB |
| Sin reportes después de | 114 s |
| Reciprocidad | Se activa tras 24 artículos (o con la frontera vacía); hasta 64 candidatos, con los ya alcanzados primero; uno de cada 4 turnos; se abandona si confirma menos del 10 % tras 16 |

## Eliminado

`Frontier.BestFirst` y su señal de títulos (`Links.tokens/2`, campos `position` y `shared` de los trabajos).
