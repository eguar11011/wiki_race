# E3: validación del extractor

**Estado: pruebas escritas y SIN EJECUTAR.** La equivalencia con el verificador **no está demostrada**.

## Implementación

`player/lib/player/links.ex` reproduce `links/2`, `resolve/2`, `canonical/1` y `port/1` de `platform/lib/wiki_race_platform/race/verifier.ex` en `c414bb0`:

- `Floki.parse_document/1` y `Floki.attribute("a", "href")`.
- Exclusión de `#`, `javascript:` y `mailto:`.
- `URI.merge/2` contra la URL tal como aparece en el camino.
- Ruta canónica con `URI.decode/1`, sin `/` final, sin query ni fragmento.

Las descargas usan `Req.get/2` con `retry: false` y redirecciones por defecto, como el verificador. Solo cambia el timeout (5 s frente a 10 s).

Diferencias deliberadas, ninguna afecta al conjunto que compara el verificador:

- `extract/2` también devuelve la URL pedible, sin query ni fragmento.
- Si el documento no se puede parsear, devuelve `:error` y la página se descarta.
- `article?/2` solo decide qué descargar.

## Pruebas (`player/test/player/links_test.exs`)

| Tipo | Casos | Qué demuestran si pasan |
|---|---|---|
| Valores esperados escritos a mano | 18 hrefs, más base con barras, base codificada, solo `a[href]`, orden sin repetidos y URL reportable | Que el código cumple la semántica de RFC 3986 y del verificador en esos casos |
| Comparación con la copia del verificador | Casos límite de Mochiweb y `URI.merge` (espacios, entidades, `File:`, `tel:`, HTML mal formado) | Solo que no hay divergencia con la copia, sin fijar el resultado esperado |

## Pendiente

- Ejecutar las pruebas.
- Comparar con páginas reales de Kiwix y con el verificador desplegado en carreras.
