# Historial de los datos

Cada actualización de los CSV de `data/` se anota aquí: qué se añadió o corrigió, de qué fuentes y cómo se comprobó. Para aplicarla en una instalación existente: `git pull` y después `actualizar.ps1`.

## 30/10/2026 · Textos en data/ (sin cambios de datos de la liga)

- Nuevos `cronicas.csv` (93 crónicas, una por partido finalizado) y `documentos.csv` (10 de reglamento y 6 preguntas frecuentes). Hasta ahora estos textos estaban escritos dentro de `ai/generate_embeddings.sql`. Las crónicas se exportaron tal cual de la base de datos: son las mismas que ya había.
- Se reescribieron tres preguntas frecuentes que dejarían de ser ciertas al añadir jornadas («¿Qué temporada y qué jornadas contiene...?», «¿De dónde salen los datos...?» y «¿Los abonados y las entradas son reales?»).
- Los CSV de la liga no cambian.

## 24/10/2026 · Carga inicial: temporada 2026-27, jornadas 1-10

- J1-J9 completas; J10 con 3 partidos jugados y 7 programados.
- Fuentes: futbolfantasy.com (calendario, resultados, árbitros y goles), matchscan.co (jugadores y estadísticas) y Wikipedia (ciudades, estadios y capacidades).
- Comprobaciones: `docs/verificacion.md`.
