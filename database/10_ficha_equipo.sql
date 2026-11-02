/* =============================================================================
   10_ficha_equipo.sql
   Goalmetry - Idea 1: ficha de equipo. Crea el esquema analisis (solo lectura de liga):
   forma reciente, racha, rendimiento en casa y fuera, goleadores y estadio.
   Ejecución:  sqlcmd -S localhost -E -C -b -i database\10_ficha_equipo.sql
   Idempotente.
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

IF SCHEMA_ID(N'analisis') IS NULL EXEC (N'CREATE SCHEMA analisis AUTHORIZATION dbo;');
GO

-- Una fila por equipo y partido jugado: es la base de la ficha, las rachas y las curiosidades.
CREATE OR ALTER VIEW analisis.vw_ResultadoEquipo
AS
SELECT r.EquipoID, p.PartidoID, j.Numero AS Jornada, p.FechaHora, r.RivalID, rv.Nombre AS Rival, r.EsLocal, r.GF, r.GC,
       CASE WHEN r.GF > r.GC THEN 'V' WHEN r.GF = r.GC THEN 'E' ELSE 'D' END AS Resultado,
       CASE WHEN r.GF > r.GC THEN 3 WHEN r.GF = r.GC THEN 1 ELSE 0 END AS Puntos
FROM liga.Partido AS p
JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
CROSS APPLY (VALUES (p.EquipoLocalID, p.EquipoVisitanteID, 1, CAST(p.GolesLocal AS INT), CAST(p.GolesVisitante AS INT)),
                    (p.EquipoVisitanteID, p.EquipoLocalID, 0, CAST(p.GolesVisitante AS INT), CAST(p.GolesLocal AS INT)))
            AS r (EquipoID, RivalID, EsLocal, GF, GC)
JOIN liga.Equipo AS rv ON rv.EquipoID = r.RivalID
WHERE p.Estado = 'Finalizado';
GO

CREATE OR ALTER VIEW analisis.vw_FichaEquipo
AS
SELECT e.EquipoID, e.Nombre, e.Ciudad, es.Nombre AS Estadio, es.Capacidad,
       c.Posicion, COALESCE(c.Pts, 0) AS Pts, COALESCE(c.PJ, 0) AS PJ, COALESCE(c.G, 0) AS G, COALESCE(c.E, 0) AS E, COALESCE(c.P, 0) AS P,
       COALESCE(c.GF, 0) AS GF, COALESCE(c.GC, 0) AS GC, COALESCE(c.DG, 0) AS DG,
       l.PJ AS LocalPJ, l.G AS LocalG, l.E AS LocalE, l.P AS LocalP, l.GF AS LocalGF, l.GC AS LocalGC, l.Pts AS LocalPts,
       v.PJ AS FueraPJ, v.G AS FueraG, v.E AS FueraE, v.P AS FueraP, v.GF AS FueraGF, v.GC AS FueraGC, v.Pts AS FueraPts
FROM liga.Equipo AS e
LEFT JOIN liga.Estadio AS es ON es.EquipoID = e.EquipoID
LEFT JOIN liga.vw_Clasificacion AS c ON c.EquipoID = e.EquipoID
OUTER APPLY (SELECT COUNT(*) AS PJ, SUM(CASE WHEN Resultado = 'V' THEN 1 ELSE 0 END) AS G, SUM(CASE WHEN Resultado = 'E' THEN 1 ELSE 0 END) AS E,
                    SUM(CASE WHEN Resultado = 'D' THEN 1 ELSE 0 END) AS P, SUM(GF) AS GF, SUM(GC) AS GC, SUM(Puntos) AS Pts
             FROM analisis.vw_ResultadoEquipo AS r WHERE r.EquipoID = e.EquipoID AND r.EsLocal = 1) AS l
OUTER APPLY (SELECT COUNT(*) AS PJ, SUM(CASE WHEN Resultado = 'V' THEN 1 ELSE 0 END) AS G, SUM(CASE WHEN Resultado = 'E' THEN 1 ELSE 0 END) AS E,
                    SUM(CASE WHEN Resultado = 'D' THEN 1 ELSE 0 END) AS P, SUM(GF) AS GF, SUM(GC) AS GC, SUM(Puntos) AS Pts
             FROM analisis.vw_ResultadoEquipo AS r WHERE r.EquipoID = e.EquipoID AND r.EsLocal = 0) AS v;
GO

/* Devuelve 3 conjuntos: la ficha (con la racha), los partidos por fecha y los goleadores.
   La forma se ordena por fecha, no por jornada: hay partidos adelantados y aplazados. */
CREATE OR ALTER PROCEDURE analisis.usp_FichaEquipo
    @EquipoID INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM liga.Equipo WHERE EquipoID = @EquipoID)
        THROW 50801, N'Ese equipo no existe.', 1;

    SELECT r.Resultado, ROW_NUMBER() OVER (ORDER BY r.FechaHora DESC, r.Jornada DESC) AS N
    INTO #O FROM analisis.vw_ResultadoEquipo AS r WHERE r.EquipoID = @EquipoID;

    DECLARE @Ult CHAR(1) = (SELECT Resultado FROM #O WHERE N = 1);
    DECLARE @Total INT = (SELECT COUNT(*) FROM #O);
    DECLARE @Racha INT = COALESCE((SELECT MIN(N) - 1 FROM #O WHERE Resultado <> @Ult), @Total);
    DECLARE @Invicto INT = COALESCE((SELECT MIN(N) - 1 FROM #O WHERE Resultado = 'D'), @Total);

    SELECT f.*, @Ult AS RachaTipo, @Racha AS RachaPartidos, @Invicto AS PartidosSinPerder
    FROM analisis.vw_FichaEquipo AS f WHERE f.EquipoID = @EquipoID;

    SELECT PartidoID, Jornada, FechaHora, RivalID, Rival, EsLocal, GF, GC, Resultado, Puntos
    FROM analisis.vw_ResultadoEquipo WHERE EquipoID = @EquipoID
    ORDER BY FechaHora, Jornada;

    SELECT TOP (5) m.Anotador, m.Goles, m.Penaltis
    FROM liga.vw_MaximosGoleadores AS m JOIN liga.Equipo AS e ON e.Nombre = m.Equipo
    WHERE e.EquipoID = @EquipoID ORDER BY m.Goles DESC, m.Anotador;
END;
GO

IF DATABASE_PRINCIPAL_ID(N'rol_web_publico') IS NOT NULL
BEGIN
    GRANT SELECT ON SCHEMA::analisis TO rol_web_publico;
    GRANT EXECUTE ON OBJECT::analisis.usp_FichaEquipo TO rol_web_publico;
END;
GO
