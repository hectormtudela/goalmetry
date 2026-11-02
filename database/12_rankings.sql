/* =============================================================================
   12_rankings.sql
   Goalmetry - Idea 4: rankings por 90 minutos, con filtro de posición y mínimo de minutos.
   Usa la ficha de cada jugador (liga.Jugador): minutos, goles y asistencias de la fuente de
   jugadores, con su propia fecha de corte (UltimaJornada). No es el recuento de liga.Gol.
   Ejecución:  sqlcmd -S localhost -E -C -b -i database\12_rankings.sql
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

CREATE OR ALTER VIEW analisis.vw_JugadorPor90
AS
SELECT j.JugadorID, j.Nombre, e.EquipoID, e.Nombre AS Equipo, j.Posicion, j.MinutosJugados, j.Goles, j.Asistencias, j.UltimaJornada,
       CASE WHEN j.MinutosJugados > 0 THEN 90.0 * j.Goles / j.MinutosJugados END AS GolesPor90,
       CASE WHEN j.MinutosJugados > 0 THEN 90.0 * j.Asistencias / j.MinutosJugados END AS AsistenciasPor90,
       CASE WHEN j.MinutosJugados > 0 THEN 90.0 * (j.Goles + j.Asistencias) / j.MinutosJugados END AS GAPor90,
       CASE WHEN j.Goles > 0 THEN 1.0 * j.MinutosJugados / j.Goles END AS MinutosPorGol
FROM liga.Jugador AS j JOIN liga.Equipo AS e ON e.EquipoID = j.EquipoID;
GO

-- @Orden: 'ga' (goles + asistencias por 90) o 'minutos' (minutos por gol, de menos a más).
CREATE OR ALTER PROCEDURE analisis.usp_Rankings
    @Posicion   CHAR(2)     = NULL,
    @MinMinutos INT         = 360,
    @Orden      VARCHAR(10) = 'ga',
    @Top        INT         = 30
AS
BEGIN
    SET NOCOUNT ON;
    IF @Posicion IS NOT NULL AND @Posicion NOT IN ('PT', 'DF', 'MC', 'DL')
        THROW 50802, N'Posición no válida.', 1;
    IF @MinMinutos NOT BETWEEN 0 AND 4000
        THROW 50803, N'El mínimo de minutos debe estar entre 0 y 4.000.', 1;
    IF @Orden NOT IN ('ga', 'minutos')
        THROW 50804, N'Orden no válido.', 1;

    SELECT TOP (@Top) ROW_NUMBER() OVER (ORDER BY CASE WHEN @Orden = 'ga' THEN -r.GAPor90 ELSE r.MinutosPorGol END, r.Nombre) AS N,
           r.JugadorID, r.Nombre, r.EquipoID, r.Equipo, r.Posicion, r.MinutosJugados, r.Goles, r.Asistencias, r.UltimaJornada,
           CAST(r.GolesPor90 AS DECIMAL(5,2)) AS GolesPor90, CAST(r.AsistenciasPor90 AS DECIMAL(5,2)) AS AsistenciasPor90,
           CAST(r.GAPor90 AS DECIMAL(5,2)) AS GAPor90, CAST(r.MinutosPorGol AS DECIMAL(7,1)) AS MinutosPorGol
    FROM analisis.vw_JugadorPor90 AS r
    WHERE r.MinutosJugados >= @MinMinutos AND r.MinutosJugados > 0
      AND (@Posicion IS NULL OR r.Posicion = @Posicion)
      AND (@Orden = 'ga' OR r.Goles > 0)
    ORDER BY N;
END;
GO

IF DATABASE_PRINCIPAL_ID(N'rol_web_publico') IS NOT NULL
    GRANT EXECUTE ON OBJECT::analisis.usp_Rankings TO rol_web_publico;
GO
