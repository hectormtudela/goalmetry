# Datos de Goalmetry (CSV)

Esta carpeta es la **fuente de verdad** del proyecto. `instalar.ps1` crea la base de datos a partir de estos ficheros, y `actualizar.ps1` carga lo que haya cambiado en ellos sin reinstalar.

Todos los ficheros son UTF-8, separados por comas, con cabecera en la primera fila y fin de línea LF (lo garantiza `.gitattributes`). Los campos vacíos son NULL. Los textos con comas van entre comillas dobles (`"..."`), y una comilla dentro de un texto se escribe doble (`""`).

| Fichero | Filas (J1-J10) | Tabla destino |
|---|---:|---|
| temporadas.csv | 1 | liga.Temporada |
| equipos.csv | 20 | liga.Equipo |
| estadios.csv | 20 | liga.Estadio |
| arbitros.csv | 21 | liga.Arbitro |
| jornadas.csv | 10 | liga.Jornada |
| partidos.csv | 100 | liga.Partido |
| jugadores.csv | 452 | liga.Jugador |
| goles.csv | 298 | liga.Gol |
| cronicas.csv | 100 | ia.Documento (tipo `cronica_partido`) |
| documentos.csv | 16 | ia.Documento (tipos `reglamento` y `faq`) |

Orden de carga (por las claves foráneas): temporadas, equipos, estadios, arbitros, jornadas, partidos, jugadores, goles. Los identificadores (`*_id`) vienen ya asignados en los CSV y se cargan con `SET IDENTITY_INSERT`.

## Valores

- `posicion`: PT (portero), DF (defensa), MC (mediocentro), DL (delantero). Un jugador queda sin posición (NULL).
- `goles.csv`: `jugador_id` vacío = anotador que no figura en jugadores.csv (5 goles). `tipo`: Normal, Penalti o PropiaPuerta (en propia puerta, `equipo_id` es el equipo beneficiado y `jugador_id` el defensor que la marca).
- `partidos.csv`: `estado` es Finalizado o Programado. Un partido programado no lleva marcador (`goles_local` y `goles_visitante` vacíos). El estadio es siempre el del equipo local.
- `cronicas.csv`: una crónica por partido finalizado (`partido_id, titulo, texto, fuente`). El título es `Local X-Y Visitante (jornada N)`: si no coincide con el marcador, la carga avisa. Si a un partido finalizado le falta su crónica, se genera una con los datos y también se avisa.
- `documentos.csv`: reglamento y preguntas frecuentes (`tipo, titulo, texto, fuente`). Solo admite los tipos `reglamento` y `faq`.

Las **fichas de equipo** y los **resúmenes de jornada** no están aquí: se calculan a partir de las tablas (vistas `ia.vw_FichaEquipo` e `ia.vw_ResumenJornada`), así siempre cuadran con la clasificación.

## Cómo se añade una jornada

Un CSV por tabla, con dos reglas: **las filas nuevas se añaden al final** y **las que cambian se modifican en su sitio**. Nunca se borra ni se renumera una fila.

1. `jornadas.csv`: una fila nueva al final con el siguiente `jornada_id` y su número.
2. `partidos.csv`:
   - los 10 partidos de la jornada nueva, al final, con los siguientes `partido_id`;
   - los que aún no se han jugado van como `Programado`, sin marcador;
   - un partido que se acaba de jugar (de esta o de una jornada anterior, por ejemplo uno aplazado) **se cambia en su fila**: marcador y `Finalizado`.
3. `goles.csv`: los goles de los partidos jugados, al final, con los siguientes `gol_id`.
4. `jugadores.csv`: se actualizan en su fila los minutos, goles, asistencias y `ultima_jornada`; los jugadores nuevos van al final.
5. `arbitros.csv`: los árbitros nuevos, al final.
6. `cronicas.csv`: una crónica por cada partido que pasa a `Finalizado`, solo con hechos de los datos (resultado, estadio, fecha, árbitro y goles). Las actuales siguen la plantilla de la vista `ia.vw_CronicaGenerada`; si se añade algo más, tiene que estar verificado y llevar su fuente en la columna `fuente`.
7. `CAMBIOS.md`: qué se añadió, de qué fuentes y cómo se comprobó.

Después, `actualizar.ps1 -Simular` enseña exactamente qué filas son nuevas y cuáles cambian, antes de aplicar nada.

**No se tocan las ventas:** `ventas.Abonado` y `ventas.Entrada` no tienen CSV. Son ficticias, las genera `03_insert_data.sql` solo para las jornadas 1-10 y son fijas.

Ver `docs/verificacion.md` para el detalle de fuentes y comprobaciones.
