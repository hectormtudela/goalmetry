# Historial de los datos

Cada actualización de los CSV de `data/` se anota aquí: qué se añadió o corrigió, de qué fuentes y cómo se comprobó. Para aplicarla en una instalación existente: `git pull` y después `actualizar.ps1`.

## 19/11/2026 · Rayo-Athletic (J8): fecha de reanudación

- **Partido 72:** `fecha_hora` pasa de 2026-10-10 14:00 a **2026-12-09 20:00** (la reanudación). Sigue `Programado`, sin marcador.
- **Qué pasó:** se suspendió el 10-10-2026 hacia el minuto 25 con 0-0 por incidentes y lanzamiento de objetos en Vallecas; se retoma el miércoles 9-12-2026 a las 20:00 y sin público.
- **Fuentes:** fecha y puerta cerrada, Comuniate (una sola fuente; laliga.com no se puede leer sin JavaScript). Minuto y marcador: la ficha de futbolfantasy.com, cuyo relato llega al 24:20, con 25 minutos jugados y ningún gol registrado.
- **Cuidado:** al jugarse es una reanudación, no un partido nuevo. Al cargarlo hay que sumar los goles al 0-0 y ajustar `tests/tests.sql` (ver «Estado» en la documentación de carga).

## 19/11/2026 · Estadísticas de jugadores hasta la J12

- **Jugadores:** los 452 actualizados en su fila (minutos, goles, asistencias y `ultima_jornada` = 12) y 30 nuevos al final (`jugador_id` 453 a 482), con su posición (Alejandro Santiago y Jan Peries no la tienen en la fuente: quedan sin posición).
- **Goles:** 3 enlazados con su jugador, que antes no tenía ficha: gol 18 (Pablo García, Betis), gol 240 (Robbie Ure, Sevilla) y gol 32 («Joaquín Oso» = Oso, Sevilla). Solo se enlaza si coinciden equipo, apellido y número de goles.
- **Fuente:** matchscan.co, plantilla de cada equipo (datos a 08-11-2026), con una lectura puntual de las 20 páginas y su `robots.txt` respetado.
- **Comprobaciones:** los 452 jugadores casan con la fuente por equipo y nombre; **los goles de cada uno coinciden con los de las actas (`goles.csv`) en los 452**; ninguna estadística baja respecto a lo que había; los minutos no superan 90 por partido jugado; las posiciones son idénticas. Rayo y Athletic aparecen con un partido menos, igual que en nuestros datos (el aplazado de la J8).

## 19/11/2026 · Jornadas 11 y 12

- **Jornadas:** 11 y 12 (`jornada_id` 11 y 12), las dos completas (20 partidos jugados).
- **Partidos:** 20 nuevos (101 a 120), todos Finalizado, con fecha y hora de la ficha de cada partido. El estadio es el del equipo local.
- **Árbitros:** ya existían todos; no se añade ninguno.
- **Goles:** 46 nuevos (`gol_id` 299 a 344; total 298 → 344): 44 normales, 2 de penalti y 0 en propia puerta. Alias aplicados, los mismos que ya se usaban: «Álex Grimaldo» = Alejandro Grimaldo y «Orri Steinn Óskarsson» = Orri Óskarsson.
- **Crónicas:** 20 nuevas (total 100 → 120), con la plantilla de `ia.vw_CronicaGenerada` (comprobado que reproduce idénticas las 10 de la J10).
- **Fuentes:** futbolfantasy.com (calendario y ficha de cada partido: fecha, árbitro y goles). Contraste con football-data.co.uk (20 de 20 marcadores y fechas coinciden) y con la clasificación de matchscan.co a 08-11-2026 (18 de 20 equipos idénticos; los dos que difieren, Athletic y Rayo, por el partido de abajo).
- **Comprobaciones:** marcador del calendario = marcador de la ficha = suma de goleadores en los 20 partidos; cada jornada tiene 10 partidos con los 20 equipos una vez; el lector de las fichas reproduce la J10 que ya estaba (8 de 10 partidos idénticos; en 2 goles hay un minuto de diferencia, porque la J10 se completó con laliga.com y no se han modificado).
- **Rayo Vallecano–Athletic de la J8 (partido 72) pasa a aplazado**, por indicación del alumno. Su 0-0 era dudoso: la ficha de futbolfantasy estaba congelada en el descanso (último dato a las 14:43 de un partido de las 14:00) y ni football-data ni matchscan lo registraban. Queda `Programado`, sin marcador, conservando su fecha original y su árbitro (las entradas ficticias de `ventas` apuntan a ese partido y no se tocan), y se quita su crónica (total 120 → 119). Con esto la clasificación coincide con la de matchscan en los 20 equipos. Cuando se juegue, se cambia en su fila y se añade su crónica.
- **`jugadores.csv`:** se actualiza en la entrada de arriba, de la misma fecha.
- Las ventas (`ventas.Abonado` y `ventas.Entrada`) no se tocan.

## 30/10/2026 · Jornada 10 completada

- **Partidos:** los 7 que faltaban por jugar (94 a 100) pasan a Finalizado con su marcador. El 92 (Rayo Vallecano 0-3 Elche CF) ya estaba finalizado, pero no tenía goleadores.
- **Árbitros:** se añade el árbitro de los partidos 97 a 100. Ya existían todos en `arbitros.csv`; no se añade ninguno.
- **Goles:** 19 nuevos (`gol_id` 280 a 298; total 279 → 298), ninguno en propia puerta. El Celta Vigo–Real Betis (97) acabó 0-0.
- **Crónicas:** 7 nuevas (partidos 94 a 100) y la del 92 actualizada con sus goleadores (total 93 → 100).
- **Fuentes:**
  - Partidos 92 a 99: fichas de partido de laliga.com (marcadores, goles, minutos y árbitros).
  - Partido 100 (Sevilla–Osasuna): no se abrió la ficha de LaLiga. Se usaron elgoldigital.com y karlobag.eu (esta cita el informe de LaLiga), y coinciden en goleadores, minutos y árbitro.
- **Notas de comprobación:**
  - Clásico (99): antes del partido se daba por designado a Alejandro Hernández Hernández, pero la ficha de LaLiga indica a Juan Martínez Munuera, que es el que se usa.
  - Primer gol de Mbappé (99, minuto 41): rebotó en un despeje de Gerard Martín, pero LaLiga lo acredita a Mbappé. Por eso no es en propia puerta.
  - Segundo gol de Mbappé: minuto 87 en LaLiga y 88 en la crónica del Real Madrid. Se usa el 87.
  - Valencia–Villarreal (94): el penalti de Pepelu es del minuto 38 en LaLiga (otras crónicas dicen 37 o 39). El gol de Mikautadze, 90+6, se guarda como minuto 96 (algunas crónicas dicen 95).
  - Julián Álvarez figura en `jugadores.csv` como «Julián Alvarez» (id 40), y así consta el anotador.
  - Comprobado con un script: por partido, los goles de cada equipo coinciden con el marcador, y cada `jugador_id` existe en `jugadores.csv` con ese `equipo_id` y el mismo nombre que el anotador.
- **Sin cambios:** las estadísticas de los jugadores (minutos, goles y asistencias) siguen hasta la J9; no se ha tocado `jugadores.csv`. Tampoco las ventas.

## 30/10/2026 · Textos en data/ (sin cambios de datos de la liga)

- Nuevos `cronicas.csv` (93 crónicas, una por partido finalizado) y `documentos.csv` (10 de reglamento y 6 preguntas frecuentes). Hasta ahora estos textos estaban escritos dentro de `ai/generate_embeddings.sql`. Las crónicas se exportaron tal cual de la base de datos: son las mismas que ya había.
- Se reescribieron tres preguntas frecuentes que dejarían de ser ciertas al añadir jornadas («¿Qué temporada y qué jornadas contiene...?», «¿De dónde salen los datos...?» y «¿Los abonados y las entradas son reales?»).
- Los CSV de la liga no cambian.

## 24/10/2026 · Carga inicial: temporada 2026-27, jornadas 1-10

- J1-J9 completas; J10 con 3 partidos jugados y 7 programados.
- Fuentes: futbolfantasy.com (calendario, resultados, árbitros y goles), matchscan.co (jugadores y estadísticas) y Wikipedia (ciudades, estadios y capacidades).
- Comprobaciones: `docs/verificacion.md`.
