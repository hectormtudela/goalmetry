/* =============================================================================
   18_proxima_jornada.sql
   Goalmetry - Idea 12: estimación de la próxima jornada con el calendario externo.
   Por cada partido: goles esperados (Poisson), 1X2 y marcador más probable.
   Son ESTIMACIONES sobre un calendario de fuente externa (externo.PartidoFuturo), nunca resultados.
   Ejecución:  sqlcmd -S localhost -E -C -b -i database\18_proxima_jornada.sql
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

CREATE OR ALTER FUNCTION simulacion.fn_MarcadorProbable (@LamL FLOAT, @LamV FLOAT)
RETURNS TABLE
AS RETURN
SELECT TOP (1) a.Goles AS GolesLocal, b.Goles AS GolesVisitante, a.P * b.P AS P
FROM simulacion.PoissonPmf AS a CROSS JOIN simulacion.PoissonPmf AS b
WHERE a.LamIdx = LEAST(160, GREATEST(1, CONVERT(INT, ROUND(@LamL / 0.05, 0))))
  AND b.LamIdx = LEAST(160, GREATEST(1, CONVERT(INT, ROUND(@LamV / 0.05, 0))))
ORDER BY a.P * b.P DESC, a.Goles DESC, b.Goles;
GO

/* Un partido APLAZADO es uno programado de una jornada anterior a la última con partidos jugados: no es «la próxima
   jornada» (esa es la siguiente del calendario) y se enseña aparte. */
CREATE OR ALTER PROCEDURE simulacion.usp_ProximaJornada
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @c TINYINT = (SELECT MAX(Jornada) FROM analisis.vw_ResultadoEquipo), @K FLOAT = 5;
    DECLARE @prox TINYINT = (SELECT MIN(f.Jornada) FROM externo.PartidoFuturo AS f
                             WHERE NOT EXISTS (SELECT 1 FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
                                               WHERE p.EquipoLocalID = f.LocalID AND p.EquipoVisitanteID = f.VisitanteID AND p.Estado = 'Programado' AND j.Numero < @c));

    SELECT @prox AS Jornada, @c AS DatosHasta, (SELECT MAX(Importado) FROM externo.PartidoFuturo) AS Importado;

    SELECT f.Jornada, f.Fecha, f.Contrastado, f.Fuente, f.LocalID, f.VisitanteID, l.Nombre AS Local, v.Nombre AS Visitante,
           g.LamL, g.LamV, s.P1, s.PX, s.P2, m.GolesLocal, m.GolesVisitante, m.P AS PMarcador,
           CASE WHEN f.Contrastado = 1 AND f.Fecha < CAST(SYSDATETIME() AS DATE) THEN 1 ELSE 0 END AS FechaPasada
    FROM externo.PartidoFuturo AS f
    JOIN liga.Equipo AS l ON l.EquipoID = f.LocalID
    JOIN liga.Equipo AS v ON v.EquipoID = f.VisitanteID
    JOIN simulacion.fn_GolesEsperados(@c, @K) AS g ON g.LocalID = f.LocalID AND g.VisitanteID = f.VisitanteID
    CROSS APPLY simulacion.fn_Probabilidad1X2(g.LamL, g.LamV) AS s
    CROSS APPLY simulacion.fn_MarcadorProbable(g.LamL, g.LamV) AS m
    WHERE f.Jornada = @prox
    ORDER BY f.Fecha, l.Nombre;

    -- Aplazados: de liga.Partido (datos reales), con la estimación de siempre.
    SELECT j.Numero AS Jornada, p.FechaHora AS FechaOriginal, p.EquipoLocalID AS LocalID, p.EquipoVisitanteID AS VisitanteID,
           l.Nombre AS Local, v.Nombre AS Visitante, s.P1, s.PX, s.P2, m.GolesLocal, m.GolesVisitante, m.P AS PMarcador
    FROM liga.Partido AS p
    JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
    JOIN liga.Equipo AS l ON l.EquipoID = p.EquipoLocalID
    JOIN liga.Equipo AS v ON v.EquipoID = p.EquipoVisitanteID
    JOIN simulacion.fn_GolesEsperados(@c, @K) AS g ON g.LocalID = p.EquipoLocalID AND g.VisitanteID = p.EquipoVisitanteID
    CROSS APPLY simulacion.fn_Probabilidad1X2(g.LamL, g.LamV) AS s
    CROSS APPLY simulacion.fn_MarcadorProbable(g.LamL, g.LamV) AS m
    WHERE p.Estado = 'Programado' AND j.Numero < @c
    ORDER BY j.Numero, l.Nombre;
END;
GO

/* La fecha solo sirve para decir «congelada» si está contrastada con dos fuentes.
   Un mismo partido puede venir de las dos fuentes (liga.Partido programado y el calendario externo): se queda una sola vez,
   con la de liga.Partido. Los aplazados no cuentan como «próxima jornada». */
CREATE OR ALTER PROCEDURE simulacion.usp_CongelarPredicciones
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @c TINYINT = (SELECT MAX(Jornada) FROM analisis.vw_ResultadoEquipo), @K FLOAT = 5;
    IF @c IS NULL RETURN;

    ;WITH U AS
    (
        SELECT j.Numero AS Jornada, p.EquipoLocalID AS L, p.EquipoVisitanteID AS V, CONVERT(DATETIME2(0), p.FechaHora) AS Inicio, 1 AS Origen
        FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
        WHERE p.Estado = 'Programado' AND j.Numero >= @c
        UNION ALL
        SELECT f.Jornada, f.LocalID, f.VisitanteID,
               CASE WHEN f.Contrastado = 1 THEN DATEADD(MINUTE, COALESCE(DATEDIFF(MINUTE, 0, TRY_CONVERT(TIME(0), f.Hora)), 0), CONVERT(DATETIME2(0), f.Fecha)) END, 2
        FROM externo.PartidoFuturo AS f
        WHERE NOT EXISTS (SELECT 1 FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
                          WHERE p.EquipoLocalID = f.LocalID AND p.EquipoVisitanteID = f.VisitanteID AND p.Estado = 'Programado' AND j.Numero < @c)
    )
    SELECT Jornada, L, V, Inicio INTO #F
    FROM (SELECT U.*, ROW_NUMBER() OVER (PARTITION BY L, V ORDER BY Origen) AS rn FROM U) AS z
    WHERE rn = 1;
    DECLARE @prox TINYINT = (SELECT MIN(Jornada) FROM #F);

    INSERT INTO simulacion.Prediccion_Historico (Modelo, Jornada, LocalID, VisitanteID, P1, PX, P2, DatosHasta, Tipo)
    SELECT 'Poisson', f.Jornada, f.L, f.V, s.P1, s.PX, s.P2, @c,
           CASE WHEN f.Inicio > SYSDATETIME() THEN 'Congelada' ELSE 'Retrospectiva' END
    FROM #F AS f
    JOIN simulacion.fn_GolesEsperados(@c, @K) AS g ON g.LocalID = f.L AND g.VisitanteID = f.V
    CROSS APPLY simulacion.fn_Probabilidad1X2(g.LamL, g.LamV) AS s
    WHERE f.Jornada = @prox
      AND NOT EXISTS (SELECT 1 FROM simulacion.Prediccion_Historico AS h WHERE h.Modelo = 'Poisson' AND h.LocalID = f.L AND h.VisitanteID = f.V);
END;
GO

IF DATABASE_PRINCIPAL_ID(N'rol_web_publico') IS NOT NULL
    GRANT EXECUTE ON OBJECT::simulacion.usp_ProximaJornada TO rol_web_publico;
GO
