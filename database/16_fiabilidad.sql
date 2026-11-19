/* =============================================================================
   16_fiabilidad.sql
   Goalmetry - Idea 11: panel de fiabilidad. Guarda probabilidades 1X2 por partido y las
   compara con lo que pasó.
     - Retrospectiva: calculada DESPUÉS de jugarse, usando solo los partidos anteriores.
       Es una prueba honesta del método, pero no una predicción hecha de verdad antes.
     - Congelada: guardada ANTES de que empiece el partido (actualizar.ps1 lo hace antes
       de cargar cada jornada nueva). Estas son las que cuentan de verdad.
   Ejecución:  sqlcmd -S localhost -E -C -b -i database\16_fiabilidad.sql
   Idempotente: no borra el histórico.
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

IF OBJECT_ID(N'simulacion.Prediccion_Historico', N'U') IS NULL
CREATE TABLE simulacion.Prediccion_Historico
(
    PrediccionID INT IDENTITY(1,1) NOT NULL,
    Modelo       VARCHAR(24)  NOT NULL,
    Jornada      TINYINT      NOT NULL,
    LocalID      INT          NOT NULL,
    VisitanteID  INT          NOT NULL,
    P1 FLOAT NOT NULL, PX FLOAT NOT NULL, P2 FLOAT NOT NULL,
    DatosHasta   TINYINT      NOT NULL,   -- última jornada usada para calcularla
    Tipo         VARCHAR(14)  NOT NULL,   -- Retrospectiva | Congelada
    FechaCongelacion DATETIME2(0) NOT NULL CONSTRAINT DF_Prediccion_Fecha DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_Prediccion_Historico PRIMARY KEY (PrediccionID),
    CONSTRAINT UQ_Prediccion UNIQUE (Modelo, LocalID, VisitanteID),
    CONSTRAINT CK_Prediccion_Tipo CHECK (Tipo IN ('Retrospectiva', 'Congelada'))
);

-- Probabilidad de cada número de goles según la media (a partir de simulacion.Poisson).
IF OBJECT_ID(N'simulacion.PoissonPmf', N'U') IS NULL
CREATE TABLE simulacion.PoissonPmf
(
    LamIdx SMALLINT NOT NULL, Goles TINYINT NOT NULL, P FLOAT NOT NULL,
    CONSTRAINT PK_PoissonPmf PRIMARY KEY (LamIdx, Goles)
);
GO
IF NOT EXISTS (SELECT 1 FROM simulacion.PoissonPmf)
    INSERT INTO simulacion.PoissonPmf (LamIdx, Goles, P)
    SELECT LamIdx, Goles, COUNT(*) / 1000.0 FROM simulacion.Poisson GROUP BY LamIdx, Goles;
GO

/* Goles esperados de todos los cruces con los partidos jugados hasta @Hasta, con el mismo
   modelo que la simulación (sin el ruido, que aquí no aporta). */
CREATE OR ALTER FUNCTION simulacion.fn_GolesEsperados (@Hasta TINYINT, @K FLOAT)
RETURNS TABLE
AS RETURN
WITH Medias AS
(
    SELECT AVG(CASE WHEN EsLocal = 1 THEN GF * 1.0 END) AS mL, AVG(CASE WHEN EsLocal = 0 THEN GF * 1.0 END) AS mV, AVG(GF * 1.0) AS m
    FROM analisis.vw_ResultadoEquipo WHERE Jornada <= @Hasta
),
Fuerza AS
(
    SELECT e.EquipoID,
           ((COALESCE(SUM(r.GF), 0) + @K * x.m) / (COUNT(r.PartidoID) + @K)) / x.m AS A,
           ((COALESCE(SUM(r.GC), 0) + @K * x.m) / (COUNT(r.PartidoID) + @K)) / x.m AS D
    FROM liga.Equipo AS e CROSS JOIN Medias AS x
    LEFT JOIN analisis.vw_ResultadoEquipo AS r ON r.EquipoID = e.EquipoID AND r.Jornada <= @Hasta
    GROUP BY e.EquipoID, x.m
)
SELECT l.EquipoID AS LocalID, v.EquipoID AS VisitanteID,
       x.mL * l.A * v.D AS LamL, x.mV * v.A * l.D AS LamV
FROM Fuerza AS l CROSS JOIN Fuerza AS v CROSS JOIN Medias AS x
WHERE l.EquipoID <> v.EquipoID;
GO

-- 1X2 a partir de los goles esperados, cruce a cruce.
CREATE OR ALTER FUNCTION simulacion.fn_Probabilidad1X2 (@LamL FLOAT, @LamV FLOAT)
RETURNS TABLE
AS RETURN
SELECT SUM(CASE WHEN a.Goles > b.Goles THEN a.P * b.P ELSE 0 END) AS P1,
       SUM(CASE WHEN a.Goles = b.Goles THEN a.P * b.P ELSE 0 END) AS PX,
       SUM(CASE WHEN a.Goles < b.Goles THEN a.P * b.P ELSE 0 END) AS P2
FROM simulacion.PoissonPmf AS a CROSS JOIN simulacion.PoissonPmf AS b
WHERE a.LamIdx = LEAST(160, GREATEST(1, CONVERT(INT, ROUND(@LamL / 0.05, 0))))
  AND b.LamIdx = LEAST(160, GREATEST(1, CONVERT(INT, ROUND(@LamV / 0.05, 0))));
GO

/* Siembra lo ya jugado como RETROSPECTIVA: J3..última, cada jornada con los datos de la anterior.
   Referencias: frecuencias de la liga hasta ese momento y un tercio cada resultado.
   Las retrospectivas de partidos ya jugados se RECALCULAN cada vez: por definición se pueden reconstruir, y así una
   corrección de datos (por ejemplo, un partido que pasa a aplazado) llega también a las predicciones posteriores que lo usaron.
   Las CONGELADAS no se tocan nunca: son las que cuentan de verdad. */
CREATE OR ALTER PROCEDURE simulacion.usp_SembrarHistorico
AS
BEGIN
    SET NOCOUNT ON;
    DELETE h
    FROM simulacion.Prediccion_Historico AS h
    JOIN liga.Partido AS p ON p.EquipoLocalID = h.LocalID AND p.EquipoVisitanteID = h.VisitanteID AND p.Estado = 'Finalizado'
    WHERE h.Tipo = 'Retrospectiva' AND h.Modelo IN ('Poisson', 'Frecuencias', 'Un tercio');
    DECLARE @K FLOAT = 5, @ultima TINYINT = (SELECT MAX(Jornada) FROM analisis.vw_ResultadoEquipo), @j TINYINT = 3;
    WHILE @j <= @ultima
    BEGIN
        DECLARE @c TINYINT = @j - 1;
        SELECT p.EquipoLocalID AS L, p.EquipoVisitanteID AS V INTO #J
        FROM liga.Partido AS p JOIN liga.Jornada AS jo ON jo.JornadaID = p.JornadaID
        WHERE p.Estado = 'Finalizado' AND jo.Numero = @j;

        INSERT INTO simulacion.Prediccion_Historico (Modelo, Jornada, LocalID, VisitanteID, P1, PX, P2, DatosHasta, Tipo)
        SELECT 'Poisson', @j, x.L, x.V, s.P1, s.PX, s.P2, @c, 'Retrospectiva'
        FROM #J AS x
        JOIN simulacion.fn_GolesEsperados(@c, @K) AS g ON g.LocalID = x.L AND g.VisitanteID = x.V
        CROSS APPLY simulacion.fn_Probabilidad1X2(g.LamL, g.LamV) AS s
        WHERE NOT EXISTS (SELECT 1 FROM simulacion.Prediccion_Historico AS h WHERE h.Modelo = 'Poisson' AND h.LocalID = x.L AND h.VisitanteID = x.V);

        INSERT INTO simulacion.Prediccion_Historico (Modelo, Jornada, LocalID, VisitanteID, P1, PX, P2, DatosHasta, Tipo)
        SELECT 'Frecuencias', @j, x.L, x.V, f.P1, f.PX, f.P2, @c, 'Retrospectiva'
        FROM #J AS x
        CROSS JOIN (SELECT AVG(CASE WHEN r.Resultado = 'V' THEN 1.0 ELSE 0 END) AS P1, AVG(CASE WHEN r.Resultado = 'E' THEN 1.0 ELSE 0 END) AS PX,
                           AVG(CASE WHEN r.Resultado = 'D' THEN 1.0 ELSE 0 END) AS P2
                    FROM analisis.vw_ResultadoEquipo AS r WHERE r.EsLocal = 1 AND r.Jornada <= @c) AS f
        WHERE NOT EXISTS (SELECT 1 FROM simulacion.Prediccion_Historico AS h WHERE h.Modelo = 'Frecuencias' AND h.LocalID = x.L AND h.VisitanteID = x.V);

        INSERT INTO simulacion.Prediccion_Historico (Modelo, Jornada, LocalID, VisitanteID, P1, PX, P2, DatosHasta, Tipo)
        SELECT 'Un tercio', @j, x.L, x.V, 1.0/3, 1.0/3, 1.0/3, @c, 'Retrospectiva'
        FROM #J AS x
        WHERE NOT EXISTS (SELECT 1 FROM simulacion.Prediccion_Historico AS h WHERE h.Modelo = 'Un tercio' AND h.LocalID = x.L AND h.VisitanteID = x.V);

        DROP TABLE #J;
        SET @j += 1;
    END;
END;
GO

-- simulacion.usp_CongelarPredicciones (congela las predicciones de la próxima jornada antes de cargar sus resultados) está en
-- 18_proxima_jornada.sql, porque usa el calendario externo. Una sola definición: si estuviera aquí también, reaplicar este
-- script pisaría la versión buena.
GO

/* Cada predicción frente a lo que pasó (solo partidos ya jugados en liga.Partido). */
CREATE OR ALTER VIEW simulacion.vw_PrediccionEvaluada
AS
SELECT h.Modelo, h.Tipo, h.Jornada, h.LocalID, h.VisitanteID, h.P1, h.PX, h.P2, r.Signo,
       POWER(h.P1 - IIF(r.Signo = '1', 1, 0), 2) + POWER(h.PX - IIF(r.Signo = 'X', 1, 0), 2) + POWER(h.P2 - IIF(r.Signo = '2', 1, 0), 2) AS Brier,
       -LOG(CASE r.Signo WHEN '1' THEN h.P1 WHEN 'X' THEN h.PX ELSE h.P2 END) AS LogLoss,
       CASE WHEN r.Signo = CASE WHEN h.P1 >= h.PX AND h.P1 >= h.P2 THEN '1' WHEN h.P2 >= h.PX THEN '2' ELSE 'X' END THEN 1 ELSE 0 END AS Acierto
FROM simulacion.Prediccion_Historico AS h
JOIN liga.Partido AS p ON p.EquipoLocalID = h.LocalID AND p.EquipoVisitanteID = h.VisitanteID AND p.Estado = 'Finalizado'
CROSS APPLY (SELECT CASE WHEN p.GolesLocal > p.GolesVisitante THEN '1' WHEN p.GolesLocal = p.GolesVisitante THEN 'X' ELSE '2' END AS Signo) AS r
WHERE h.P1 > 0 AND h.PX > 0 AND h.P2 > 0;
GO

CREATE OR ALTER VIEW simulacion.vw_FiabilidadModelo
AS
SELECT Modelo, Tipo, COUNT(*) AS Partidos, AVG(Brier) AS Brier, AVG(LogLoss) AS LogLoss, SUM(Acierto) AS Aciertos
FROM simulacion.vw_PrediccionEvaluada
GROUP BY Modelo, Tipo;
GO

-- Calibración: cuando el modelo dice «X %», ¿pasa de verdad un X % de las veces? Cada resultado posible es un punto.
CREATE OR ALTER VIEW simulacion.vw_Calibracion
AS
SELECT e.Modelo, b.Tramo, COUNT(*) AS Casos, AVG(c.Prob) AS Previsto, AVG(c.Ocurrio * 1.0) AS Ocurrido
FROM simulacion.vw_PrediccionEvaluada AS e
CROSS APPLY (VALUES (e.P1, IIF(e.Signo = '1', 1, 0)), (e.PX, IIF(e.Signo = 'X', 1, 0)), (e.P2, IIF(e.Signo = '2', 1, 0))) AS c (Prob, Ocurrio)
CROSS APPLY (SELECT LEAST(CONVERT(INT, c.Prob * 5), 4) AS Tramo) AS b
GROUP BY e.Modelo, b.Tramo;
GO

EXEC simulacion.usp_SembrarHistorico;
GO

SELECT Modelo, Tipo, Partidos, CAST(Brier AS DECIMAL(6,4)) AS Brier, CAST(LogLoss AS DECIMAL(6,4)) AS LogLoss, Aciertos
FROM simulacion.vw_FiabilidadModelo ORDER BY Brier;
GO
