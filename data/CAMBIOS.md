# Historial de los datos

Cada actualización de los CSV de `data/` se anota aquí: qué se añadió o corrigió, de qué fuentes y cómo se comprobó. Para aplicarla en una instalación existente: `git pull` y después `actualizar.ps1`.

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
