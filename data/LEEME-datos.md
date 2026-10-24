# Datos de LigaDB (CSV)

Todos los ficheros son UTF-8, separados por comas, con cabecera en la primera fila. Los campos vacíos son NULL.

| Fichero | Filas | Tabla destino |
|---|---|---|
| temporadas.csv | 1 | liga.Temporada |
| equipos.csv | 20 | liga.Equipo |
| estadios.csv | 20 | liga.Estadio |
| arbitros.csv | 21 | liga.Arbitro |
| jornadas.csv | 10 | liga.Jornada |
| partidos.csv | 100 | liga.Partido |
| jugadores.csv | 452 | liga.Jugador |
| goles.csv | 279 | liga.Gol |

Orden de carga (por las claves foráneas): temporadas, equipos, estadios, arbitros, jornadas, partidos, jugadores, goles.

Los identificadores (`*_id`) vienen ya asignados en los CSV. Para cargarlos hay que activar `SET IDENTITY_INSERT ... ON` en cada tabla, o cargarlos en tablas de staging y generar los IDs en la inserción.

Ejemplo de carga con `BULK INSERT` en SQL Server 2025 (ajusta la ruta):

```sql
BULK INSERT staging.jugadores
FROM 'C:\ruta\dp800-datos\jugadores.csv'
WITH (FORMAT = 'CSV', FIRSTROW = 2, CODEPAGE = '65001', FIELDQUOTE = '"');
```

Valores de `posicion`: PT (portero), DF (defensa), MC (mediocentro), DL (delantero). Un jugador queda sin posición (NULL).
`goles.csv`: `jugador_id` vacío = anotador que no figura en jugadores.csv (5 goles). `tipo`: Normal, Penalti o PropiaPuerta (en propia puerta, `equipo_id` es el equipo beneficiado y `jugador_id` el defensor que la marca).
Valores de `estado` en partidos: Finalizado o Programado.

Ver `verificacion.md` para el detalle de fuentes y comprobaciones.
