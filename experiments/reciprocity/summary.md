# Resumen: reciprocidad de enlaces para la estrategia A

Fuente: `results.csv` y `run_metadata.json` de una ejecución completa (`stopped_by: completed`, 242,4 s). Generado con `run_experiment.py analyze` y `analyze_extra.py`, que solo leen esos archivos. El subcomando `analyze` imprime en pantalla; este archivo se escribió a partir de esa salida.

Etiquetas: **[H]** hecho en código o documentación, **[M]** medido en este experimento, **[I]** inferencia, **[P]** propuesta sin validar.

## Recomendación

**CONDITIONAL GO.** La reciprocidad es frecuente y estable en esta muestra, pero **no se ha demostrado que acelere la búsqueda**: no se midió ninguna carrera ni un BFS real de 3 saltos. Se justifica un prototipo medido, no adoptar la estrategia A.

| Condición para pasar a GO | Por qué |
|---|---|
| Comparar el tiempo al primer camino válido contra un BFS asíncrono de control, en pares de 3 saltos y con el verificador oficial | Es la utilidad competitiva, y no está medida |
| Repetir una muestra menor en `all` | `top_nopic` no es el dataset de competencia y podría sesgar la reciprocidad |
| Determinar cuántos candidatos hacen falta para que los encuentros sigan ocurriendo | Los datos solo permiten analizar la tasa para muestras menores, no el encuentro |
| Tratar los destinos que sean redirecciones | Los dos destinos redirigidos dieron las tasas más bajas de su grupo |

## Unidades (no son intercambiables)

| Unidad | Valor [M] | Definición |
|---|---|---|
| Destinos examinados | 30 | Filas `target` |
| Enlaces salientes de los destinos (C completo) | 6 486 | Suma de `out_degree` |
| Candidatos examinados con éxito | 2 733 | Filas `candidate` con `download_status=ok` |
| Candidatos no examinados | 3 753 | Filas con `download_status=not_examined` |
| Candidatos recíprocos | 1 073 | `is_reciprocal=1` entre los examinados |
| Descargas registradas | 3 882 | 103 de selección + 2 733 candidatos + 15 orígenes + 1 031 enlaces de S |
| Descargas únicas | 3 126 | Descargas menos 756 repetidas |
| Peticiones HTTP | 4 334 | 3 882 descargas + 452 redirecciones; sin reintentos |

Los totales de descargas, descargas únicas y peticiones HTTP coinciden con `run_metadata.json`. Estado de las 3 882 descargas: todas `ok`; sin errores HTTP, respuestas vacías ni fallos de extracción.

## Tasa de reciprocidad

**Denominador:** candidatos descargados con éxito de la **muestra** de cada destino. No es la reciprocidad del conjunto completo de enlaces salientes: la muestra cubre, en mediana, el 52 % de C (mínimo 16,8 %).

| Estadístico [M] | Todos (n=30) | Sin destinos redirigidos (n=28) |
|---|---|---|
| Media | 0,399 | 0,421 |
| Mediana | 0,380 | 0,390 |
| Desviación estándar | 0,160 | 0,140 |
| Mínimo | 0,000 | 0,165 |
| Percentil 10 | 0,226 | 0,280 |
| Percentil 25 | 0,310 | 0,318 |
| Percentil 75 | 0,480 | 0,492 |
| Percentil 90 | 0,641 | 0,642 |
| Máximo | 0,710 | 0,710 |

- IC 95 % de la mediana (bootstrap, todos): 0,325 a 0,455.
- Tasa agregada de la muestra: 0,393 (1 073 / 2 733). Pondera más a los destinos con más candidatos; la distribución por destino es la medida principal.

| Tasa | [0; 0,1) | [0,1; 0,2) | [0,2; 0,3) | [0,3; 0,4) | [0,4; 0,5) | [0,5; 0,6) | [0,6; 0,7) | [0,7; 0,8) |
|---|---|---|---|---|---|---|---|---|
| Destinos [M] | 1 | 2 | 4 | 9 | 7 | 3 | 3 | 1 |

### Por destino [M]

| ID | Destino | Tercio | Grado | Examinados | Recíprocos | Tasa | No examinados |
|---|---|---|---|---|---|---|---|
| T01 | Ester | 2 | 158 | 100 | 46 | 0,460 | 58 |
| T02 | Cerebellum | 1 | 107 | 100 | 33 | 0,330 | 7 |
| T03 | Glossary_of_association_football_terms | 2 | 194 | 100 | 23 | 0,230 | 94 |
| T04 | Time_(magazine) | 2 | 205 | 100 | 57 | 0,570 | 105 |
| T05 | Incarceration_in_the_United_States | 3 | 355 | 100 | 42 | 0,420 | 255 |
| T06 | Baton_Rouge,_Louisiana | 3 | 313 | 100 | 31 | 0,310 | 213 |
| T07 | Stanford_Encyclopedia_of_Philosophy | 1 | 22 | 22 | 8 | 0,364 | 0 |
| T08 | Catalogue_of_Life | 1 | 17 | 17 | 9 | 0,529 | 0 |
| T09 | Assistant_referee_(association_football) | 1 | 34 | 34 | 22 | 0,647 | 0 |
| T10 | Philomela | 1 | 81 | 81 | 24 | 0,296 | 0 |
| T11 | Public_policy_of_the_United_States | 3 | 324 | 100 | 40 | 0,400 | 224 |
| T12 | Cenozoic | 1 | 131 | 100 | 35 | 0,350 | 31 |
| T13 | Mesut_Özil | 2 | 254 | 100 | 28 | 0,280 | 154 |
| T14 | Fascism | 3 | 594 | 100 | 56 | 0,560 | 494 |
| T15 | Delphic_Oracle (redirección) | 3 | 298 | 100 | 0 | 0,000 | 198 |
| T16 | Kantian_ethics | 2 | 168 | 100 | 44 | 0,440 | 68 |
| T17 | The_Byrds | 1 | 129 | 100 | 28 | 0,280 | 29 |
| T18 | Rodent | 2 | 193 | 100 | 38 | 0,380 | 93 |
| T19 | Ruby_Bridges | 1 | 109 | 100 | 64 | 0,640 | 9 |
| T20 | National_Aeronautics_and_Space_Administration (redirección) | 3 | 378 | 100 | 19 | 0,190 | 278 |
| T21 | Dictatorship | 3 | 400 | 100 | 67 | 0,670 | 300 |
| T22 | Cinema_of_the_United_States | 3 | 448 | 100 | 38 | 0,380 | 348 |
| T23 | Mario_Mandžukić | 2 | 162 | 100 | 33 | 0,330 | 62 |
| T24 | Primate | 2 | 238 | 100 | 45 | 0,450 | 138 |
| T25 | Carson_City,_Nevada | 3 | 334 | 100 | 31 | 0,310 | 234 |
| T26 | John_Henry_(folklore) | 1 | 79 | 79 | 13 | 0,165 | 0 |
| T27 | Prince_Edward,_Duke_of_Kent_and_Strathearn | 1 | 100 | 100 | 48 | 0,480 | 0 |
| T28 | Taxonomy_(biology) | 2 | 193 | 100 | 71 | 0,710 | 93 |
| T29 | Stanford_University | 3 | 294 | 100 | 48 | 0,480 | 194 |
| T30 | Oceania_Football_Confederation | 2 | 174 | 100 | 32 | 0,320 | 74 |

## Variabilidad entre destinos

| Análisis [M] | Resultado |
|---|---|
| Correlación de Spearman entre grado y tasa | −0,026 (0,087 sin destinos redirigidos) |
| Tasa mediana por tercio de grado | 0,357 / 0,410 / 0,390 |
| Destinos con IC 95 % de Wilson con límite inferior ≥ 0,20 | 25 de 30 |
| Grado de salida | Media 216, mediana 193, desviación 136, mínimo 17, máximo 594 |

**Interpretación [I].** En esta muestra la reciprocidad se reparte por todos los tamaños de página, sin relación apreciable con el grado. No hay evidencia de que sirva solo para un tipo de destino según el grado. **No se puede concluir nada por temática**: no hay etiquetas de categoría y agruparlas a mano introduciría sesgo. La dispersión es real (desviación 0,16): el rendimiento por destino varía.

**Los destinos que son redirecciones son un caso aparte [M, I].** T15 (0/100) y T20 (19/100) son las dos URL que redirigían al seleccionarse. El verificador exige el enlace a la URL exacta del objetivo [H, `Verifier.check_hop/1`], así que un candidato que enlaza a la página final no cuenta. Son pocos casos, pero la estrategia debería detectar esta situación.

## Coste de obtener la información

| Medida | Valor [M] |
|---|---|
| Descargas por recíproco encontrado (29 destinos con alguno) | Mediana 2,6; p90 3,7; máximo 6,1 |
| Destinos con ≥ 1 recíproco en los primeros 5 / 10 / 25 / 50 candidatos | 25 / 28 / 29 / 29 de 30 |
| Recíprocos por destino | Mediana 34; p25 25; p90 57,7 |
| Destinos con ≥ 1, ≥ 5, ≥ 10 y ≥ 20 recíprocos | 29, 29, 27 y 25 de 30 |
| Latencia por descarga | Mediana 9,2 ms; p95 15,6 ms; máximo 22,5 ms |
| Tamaño por descarga | Mediana 265 KB; 1,30 GB en total |
| Tiempo extremo a extremo | 62,4 ms por descarga (incluye parseo Python y pausa de 5 ms) |

Sensibilidad de la tasa mediana al tamaño de muestra [M]: 0,40 con n=10; 0,36 con n=25; 0,40 con n=50; 0,40 con n=75; 0,38 con n=100. Es estable en mediana, aunque la dispersión baja al aumentar n.

Por posición del enlace en la página T [M]: cuartiles 0,378, 0,280, 0,379 y 0,531. El último cuartil es mayor, lo que podría reflejar plantillas de navegación al final de la página [I]; no se ha comprobado.

**Lectura [I].** La latencia se midió con un único cliente secuencial. No representa dos crawlers en carrera ni el coste de Floki en Elixir, de modo que estas cifras no se pueden convertir en tiempos de carrera.

## Comparación con la búsqueda directa

**No es una comparación de rendimiento.** Son 15 pares, con los primeros 80 enlaces de S, en descargas y sin carreras.

| Par | Enlaces de S usados | BFS 2 saltos: descargas | Con L1∩C primero: descargas | Encuentro con recíprocos: descargas | Tipo de encuentro |
|---|---|---|---|---|---|
| P01 | 80 | Sin ruta | Sin ruta | 106 | 3 saltos |
| P02 | 80 | Sin ruta | Sin ruta | 123 | 3 saltos |
| P03 | 80 | Sin ruta | Sin ruta | Sin encuentro | |
| P04 | 80 | 3 | 4 | 103 | 3 saltos |
| P05 | 80 | Sin ruta | Sin ruta | 114 | 3 saltos |
| P06 | 80 | 39 | 3 | 108 | 3 saltos |
| P07 | 79 | Sin ruta | Sin ruta | 43 | 3 saltos |
| P08 | 80 | Sin ruta | Sin ruta | Sin encuentro | |
| P09 | 70 | Sin ruta | Sin ruta | Sin encuentro | |
| P10 | 80 | Sin ruta | Sin ruta | 95 | 3 saltos |
| P11 | 1 | Sin ruta | Sin ruta | Sin encuentro | |
| P12 | 80 | 24 | 4 | 103 | 3 saltos |
| P13 | 80 | Sin ruta | Sin ruta | Sin encuentro | |
| P14 | 1 | Sin ruta | Sin ruta | 103 | 3 saltos |
| P15 | 80 | Sin ruta | Sin ruta | Sin encuentro | |

- "Sin ruta" y "Sin encuentro" significan que no se encontró dentro del límite de 80, no que no exista.
- P11 y P14 tienen orígenes con un solo enlace: casos degenerados, sin explicación comprobada.
- Se encontró ruta de 2 saltos en 3 de 15 pares y encuentro en 9 de 15. Todos los encuentros son de 3 saltos, y ninguna de esas rutas se validó con el verificador oficial.

**Costes [M].**

| Componente | Descargas |
|---|---|
| Descargar T | 1 |
| Examinar candidatos | Hasta 100 por destino, 100 en la mediana de estos pares |
| Encuentro con recíprocos | Mediana 103 (43 a 123, n=9), contando todos los candidatos por adelantado |
| Trabajo inútil posible | Los candidatos no recíprocos: 61 % de los examinados en la muestra global |

**Lo que los datos sí permiten decir [I].**

- Donde la ruta de 2 saltos existe, el examen previo de candidatos cuesta más: 103 a 108 descargas frente a 3, 39 y 24 de BFS.
- Mirar antes los enlaces de S que también están en C resolvió 2 de 3 pares con menos descargas. Solo necesita T, pero n=3.
- En 6 de los 9 encuentros no apareció ruta de 2 saltos en los primeros 80 enlaces. Un BFS necesitaría un nivel más, cuyo coste **no está medido**.

**No se puede afirmar** que la estrategia A reduzca el tiempo de búsqueda o mejore el rendimiento competitivo.

## Limitaciones

- **Extractor Python frente al verificador Elixir.** El script usa `html.parser` y `urljoin`; el verificador usa Floki (Mochiweb) y `URI.merge`. Pueden diferir con HTML mal formado y otros casos. El script también filtra espacios de nombres y recursos, cosa que el verificador no hace. **Estos resultados no son equivalentes a los del verificador.**
- **Dataset.** `top_nopic` no es `all`. Los enlaces a páginas ausentes pueden desaparecer del snapshot y alterar la reciprocidad [I]. La conclusión no se extrapola a competencia.
- **Reciprocidad no es predecesores.** Solo se ven predecesores que además aparecen en C.
- **Muestra.** Los destinos salen de un recorrido desde la portada, lo que favorece artículos conectados. 30 destinos y una semilla.
- **Muestra de candidatos.** 3 753 candidatos sin examinar; en cinco destinos la muestra es menor de 100 por tener menos enlaces.
- **Sin dependencia entre datos.** Las señales se midieron por separado: no se sabe cuántos candidatos bastan para que los encuentros se mantengan, porque el CSV no guarda las listas de enlaces.
- **Carga.** Cliente único, secuencial y sin rival.
- **Uso de los datos.** No deben incorporarse a ningún crawler: la regla de precálculo lo prohíbe.

## Respuestas

| Pregunta | Respuesta |
|---|---|
| ¿Qué proporción de C es recíproca? | Mediana 0,38 en la muestra; 0,393 agregada |
| ¿Varía entre artículos? | Sí, de 0 a 0,71, con desviación 0,16 |
| ¿Distribución del grado? | Mediana 193, de 17 a 594 |
| ¿Cuántas descargas para identificar recíprocos? | Mediana 2,6 descargas por recíproco; 25 de 30 destinos tienen al menos uno en los primeros 5 candidatos |
| ¿Latencia y volumen? | 9,2 ms de mediana y 265 KB por página, con cliente único |
| ¿Hay evidencia de que reduzca el trabajo frente a BFS? | Indicios parciales y sin comparación válida; en rutas de 2 saltos el examen previo cuesta más |

## Siguiente paso técnico

Construir el BFS asíncrono de control sobre el núcleo común y añadir la frontera inversa con un tope pequeño de candidatos [P]. Comparar ambos en pares de 3 saltos con el verificador oficial y medir el tiempo al primer camino válido, con múltiples repeticiones. Medir también en `all` si es posible.
