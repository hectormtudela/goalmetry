/* =============================================================================
   19_modelos.sql
   Goalmetry - Idea 13: otros modelos frente al Poisson del panel de fiabilidad.
     - Elo: empieza en 2024-25 con resultados externos (openfootball) y sigue con liga.Partido.
     - Poisson + tiros: como Poisson, pero ataque y defensa salen de los tiros a puerta (football-data).
     - Cuotas: media de las casas de apuestas, con el margen quitado. Es una REFERENCIA externa, no un modelo propio.
   Cada predicción de la jornada J usa solo lo jugado antes de J. Los parámetros son valores habituales,
   fijados antes de mirar los resultados y sin ajustar con estos datos (K=20, ventaja de campo=60).
   Si no hay datos externos, no se calculan estos modelos y el panel lo dice.
   Ejecución:  sqlcmd -S localhost -E -C -b -i database\19_modelos.sql
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

IF OBJECT_ID(N'simulacion.Elo_Equipo', N'U') IS NULL
CREATE TABLE simulacion.Elo_Equipo
(
    EquipoID INT NOT NULL,
    Elo      FLOAT NOT NULL,
    Fuente   VARCHAR(40) NOT NULL,
    Calculado DATETIME2(0) NOT NULL CONSTRAINT DF_Elo_Calculado DEFAULT (SYSDATETIME()),
    CONSTRAINT PK_Elo_Equipo PRIMARY KEY (EquipoID)
);
GO

CREATE OR ALTER PROCEDURE simulacion.usp_RecalcularModelos
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @KElo FLOAT = 20, @Campo FLOAT = 60, @Inicial FLOAT = 1500, @Regresion FLOAT = 2.0 / 3, @K FLOAT = 5;
    DECLARE @ultima TINYINT = (SELECT MAX(Jornada) FROM analisis.vw_ResultadoEquipo);

    DELETE FROM simulacion.Prediccion_Historico WHERE Modelo IN ('Elo', 'Poisson+tiros', 'Cuotas');
    IF @ultima IS NULL RETURN;

    /* ---------- Cuotas ---------- */
    INSERT INTO simulacion.Prediccion_Historico (Modelo, Jornada, LocalID, VisitanteID, P1, PX, P2, DatosHasta, Tipo)
    SELECT 'Cuotas', j.Numero, c.LocalID, c.VisitanteID,
           (1 / c1) / s, (1 / cx) / s, (1 / c2) / s, j.Numero - 1, 'Retrospectiva'
    FROM externo.Cuota AS c
    JOIN liga.Partido AS p ON p.EquipoLocalID = c.LocalID AND p.EquipoVisitanteID = c.VisitanteID
    JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
    CROSS APPLY (SELECT CONVERT(FLOAT, c.CuotaLocal) AS c1, CONVERT(FLOAT, c.CuotaEmpate) AS cx, CONVERT(FLOAT, c.CuotaVisitante) AS c2) AS o
    CROSS APPLY (SELECT 1 / o.c1 + 1 / o.cx + 1 / o.c2 AS s) AS t
    WHERE j.Numero >= 3;

    /* ---------- Poisson con tiros a puerta ---------- */
    IF EXISTS (SELECT 1 FROM externo.PartidoExtra WHERE APuertaL IS NOT NULL)
    BEGIN
        SELECT j.Numero AS Jornada, x.LocalID AS EquipoID, CONVERT(FLOAT, x.APuertaL) AS AF, CONVERT(FLOAT, x.APuertaV) AS AC
        INTO #T
        FROM externo.PartidoExtra AS x
        JOIN liga.Partido AS p ON p.EquipoLocalID = x.LocalID AND p.EquipoVisitanteID = x.VisitanteID
        JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
        WHERE x.APuertaL IS NOT NULL AND x.APuertaV IS NOT NULL
        UNION ALL
        SELECT j.Numero, x.VisitanteID, x.APuertaV, x.APuertaL
        FROM externo.PartidoExtra AS x
        JOIN liga.Partido AS p ON p.EquipoLocalID = x.LocalID AND p.EquipoVisitanteID = x.VisitanteID
        JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
        WHERE x.APuertaL IS NOT NULL AND x.APuertaV IS NOT NULL;

        DECLARE @j1 TINYINT = 3;
        WHILE @j1 <= @ultima
        BEGIN
            DECLARE @hasta TINYINT = @j1 - 1;
            DECLARE @s FLOAT = (SELECT AVG(AF) FROM #T WHERE Jornada <= @hasta);
            DECLARE @mL FLOAT = (SELECT AVG(CASE WHEN EsLocal = 1 THEN GF * 1.0 END) FROM analisis.vw_ResultadoEquipo WHERE Jornada <= @hasta),
                    @mV FLOAT = (SELECT AVG(CASE WHEN EsLocal = 0 THEN GF * 1.0 END) FROM analisis.vw_ResultadoEquipo WHERE Jornada <= @hasta);
            IF @s > 0
            BEGIN
                ;WITH Fuerza AS
                (
                    SELECT e.EquipoID,
                           ((COALESCE(SUM(t.AF), 0) + @K * @s) / (COUNT(t.AF) + @K)) / @s AS A,
                           ((COALESCE(SUM(t.AC), 0) + @K * @s) / (COUNT(t.AC) + @K)) / @s AS D
                    FROM liga.Equipo AS e LEFT JOIN #T AS t ON t.EquipoID = e.EquipoID AND t.Jornada <= @hasta
                    GROUP BY e.EquipoID
                )
                INSERT INTO simulacion.Prediccion_Historico (Modelo, Jornada, LocalID, VisitanteID, P1, PX, P2, DatosHasta, Tipo)
                SELECT 'Poisson+tiros', @j1, p.EquipoLocalID, p.EquipoVisitanteID, s.P1, s.PX, s.P2, @hasta, 'Retrospectiva'
                FROM liga.Partido AS p
                JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID AND j.Numero = @j1
                JOIN Fuerza AS l ON l.EquipoID = p.EquipoLocalID
                JOIN Fuerza AS v ON v.EquipoID = p.EquipoVisitanteID
                CROSS APPLY simulacion.fn_Probabilidad1X2(@mL * l.A * v.D, @mV * v.A * l.D) AS s
                WHERE p.Estado = 'Finalizado';
            END;
            SET @j1 += 1;
        END;
    END;

    /* ---------- Elo ---------- */
    DELETE FROM simulacion.Elo_Equipo;
    IF NOT EXISTS (SELECT 1 FROM externo.PartidoHistorico) RETURN;

    CREATE TABLE #E (Nombre NVARCHAR(60) COLLATE DATABASE_DEFAULT PRIMARY KEY, Elo FLOAT NOT NULL);
    INSERT #E SELECT DISTINCT n.Nombre, @Inicial
    FROM externo.PartidoHistorico AS h
    CROSS APPLY (VALUES (h.LocalNombre), (h.VisitanteNombre)) AS n (Nombre);
    -- Los equipos que no estaban (recién ascendidos a la liga de estos datos) empiezan en el valor inicial.
    INSERT #E SELECT a.NombreExterno, @Inicial FROM externo.Alias AS a
    WHERE a.Fuente = 'openfootball' AND a.NombreExterno COLLATE DATABASE_DEFAULT NOT IN (SELECT Nombre FROM #E);

    -- Empates de las temporadas anteriores: es la proporción que usa el modelo para repartir el 1X2.
    DECLARE @pE FLOAT = (SELECT AVG(CASE WHEN GolesLocal = GolesVisitante THEN 1.0 ELSE 0 END) FROM externo.PartidoHistorico);

    DECLARE @temp CHAR(7), @tempAnterior CHAR(7) = NULL, @l NVARCHAR(60), @v NVARCHAR(60), @gl INT, @gv INT, @rl FLOAT, @rv FLOAT, @ex FLOAT, @res FLOAT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT Temporada, LocalNombre, VisitanteNombre, GolesLocal, GolesVisitante FROM externo.PartidoHistorico ORDER BY Temporada, Orden;
    OPEN c;
    FETCH NEXT FROM c INTO @temp, @l, @v, @gl, @gv;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @tempAnterior IS NOT NULL AND @temp <> @tempAnterior
            UPDATE #E SET Elo = @Inicial + (Elo - @Inicial) * @Regresion;
        SET @tempAnterior = @temp;
        SELECT @rl = Elo FROM #E WHERE Nombre = @l;
        SELECT @rv = Elo FROM #E WHERE Nombre = @v;
        SET @ex = 1 / (1 + POWER(10.0E0, -(@rl - @rv + @Campo) / 400));
        SET @res = CASE WHEN @gl > @gv THEN 1 WHEN @gl = @gv THEN 0.5 ELSE 0 END;
        UPDATE #E SET Elo = Elo + @KElo * (@res - @ex) WHERE Nombre = @l;
        UPDATE #E SET Elo = Elo - @KElo * (@res - @ex) WHERE Nombre = @v;
        FETCH NEXT FROM c INTO @temp, @l, @v, @gl, @gv;
    END;
    CLOSE c; DEALLOCATE c;
    UPDATE #E SET Elo = @Inicial + (Elo - @Inicial) * @Regresion;   -- comienzo de 2026-27

    -- Temporada actual: jornada a jornada. Primero se predice con lo de antes; después se actualiza.
    DECLARE @j TINYINT = 1;
    WHILE @j <= @ultima
    BEGIN
        SELECT p.EquipoLocalID AS L, p.EquipoVisitanteID AS V, el.Elo AS RL, ev.Elo AS RV,
               1 / (1 + POWER(10.0E0, -(el.Elo - ev.Elo + @Campo) / 400)) AS Ex,
               CASE WHEN p.GolesLocal > p.GolesVisitante THEN 1.0E0 WHEN p.GolesLocal = p.GolesVisitante THEN 0.5E0 ELSE 0E0 END AS Res,
               al.NombreExterno AS NL, av.NombreExterno AS NV
        INTO #M
        FROM liga.Partido AS p
        JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID AND j.Numero = @j
        JOIN externo.Alias AS al ON al.Fuente = 'openfootball' AND al.EquipoID = p.EquipoLocalID
        JOIN externo.Alias AS av ON av.Fuente = 'openfootball' AND av.EquipoID = p.EquipoVisitanteID
        JOIN #E AS el ON el.Nombre = al.NombreExterno COLLATE DATABASE_DEFAULT
        JOIN #E AS ev ON ev.Nombre = av.NombreExterno COLLATE DATABASE_DEFAULT
        WHERE p.Estado = 'Finalizado';

        IF @j >= 3
            INSERT INTO simulacion.Prediccion_Historico (Modelo, Jornada, LocalID, VisitanteID, P1, PX, P2, DatosHasta, Tipo)
            SELECT 'Elo', @j, m.L, m.V, m.Ex - x.PX / 2, x.PX, 1 - m.Ex - x.PX / 2, @j - 1, 'Retrospectiva'
            FROM #M AS m CROSS APPLY (SELECT @pE * 4 * m.Ex * (1 - m.Ex) AS PX) AS x;

        UPDATE e SET Elo = e.Elo + d.Delta
        FROM #E AS e
        JOIN (SELECT NL COLLATE DATABASE_DEFAULT AS Nombre, SUM(@KElo * (Res - Ex)) AS Delta FROM #M GROUP BY NL
              UNION ALL
              SELECT NV COLLATE DATABASE_DEFAULT, SUM(-@KElo * (Res - Ex)) FROM #M GROUP BY NV) AS d ON d.Nombre = e.Nombre;
        DROP TABLE #M;
        SET @j += 1;
    END;

    INSERT INTO simulacion.Elo_Equipo (EquipoID, Elo, Fuente)
    SELECT a.EquipoID, e.Elo, 'openfootball y liga.Partido'
    FROM #E AS e JOIN externo.Alias AS a ON a.Fuente = 'openfootball' AND a.NombreExterno COLLATE DATABASE_DEFAULT = e.Nombre;
END;
GO

/* Todos los modelos sobre LOS MISMOS partidos. Diferencia con Poisson y su margen de error (2 errores
   estándar de la diferencia emparejada): si cabe el cero, no se puede decir que uno sea mejor. */
CREATE OR ALTER VIEW simulacion.vw_ComparacionModelos
AS
WITH Comunes AS
(
    SELECT LocalID, VisitanteID FROM simulacion.vw_PrediccionEvaluada
    GROUP BY LocalID, VisitanteID
    HAVING COUNT(DISTINCT Modelo) = (SELECT COUNT(DISTINCT Modelo) FROM simulacion.vw_PrediccionEvaluada)
)
SELECT e.Modelo, COUNT(*) AS Partidos, AVG(e.Brier) AS Brier, AVG(e.LogLoss) AS LogLoss, SUM(e.Acierto) AS Aciertos,
       AVG(e.Brier - b.Brier) AS DifBrier,
       2 * STDEV(e.Brier - b.Brier) / SQRT(COUNT(*)) AS MargenDif
FROM simulacion.vw_PrediccionEvaluada AS e
JOIN Comunes AS c ON c.LocalID = e.LocalID AND c.VisitanteID = e.VisitanteID
JOIN simulacion.vw_PrediccionEvaluada AS b ON b.Modelo = 'Poisson' AND b.LocalID = e.LocalID AND b.VisitanteID = e.VisitanteID
GROUP BY e.Modelo;
GO

/* Tarjetas de los partidos de un árbitro: fuente externa, una sola fuente y sin contrastar. */
CREATE OR ALTER PROCEDURE analisis.usp_TarjetasArbitro
    @ArbitroID INT
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH T AS
    (
        SELECT p.ArbitroPrincipalID AS ArbitroID, CONVERT(FLOAT, x.AmarillasL + x.AmarillasV) AS Am, CONVERT(FLOAT, x.RojasL + x.RojasV) AS Ro
        FROM externo.PartidoExtra AS x
        JOIN liga.Partido AS p ON p.EquipoLocalID = x.LocalID AND p.EquipoVisitanteID = x.VisitanteID
        WHERE x.AmarillasL IS NOT NULL AND x.AmarillasV IS NOT NULL AND x.RojasL IS NOT NULL AND x.RojasV IS NOT NULL
    )
    SELECT (SELECT COUNT(*) FROM T WHERE ArbitroID = @ArbitroID) AS Partidos,
           (SELECT AVG(Am) FROM T WHERE ArbitroID = @ArbitroID) AS Amarillas, (SELECT AVG(Ro) FROM T WHERE ArbitroID = @ArbitroID) AS Rojas,
           (SELECT AVG(Am) FROM T) AS AmarillasLiga, (SELECT AVG(Ro) FROM T) AS RojasLiga;
END;
GO

EXEC simulacion.usp_RecalcularModelos;
GO

IF DATABASE_PRINCIPAL_ID(N'rol_web_publico') IS NOT NULL
    GRANT EXECUTE ON OBJECT::analisis.usp_TarjetasArbitro TO rol_web_publico;
GO

SELECT Modelo, Partidos, CAST(Brier AS DECIMAL(6,4)) AS Brier, CAST(LogLoss AS DECIMAL(6,4)) AS LogLoss, Aciertos,
       CAST(DifBrier AS DECIMAL(6,4)) AS DifBrier, CAST(MargenDif AS DECIMAL(6,4)) AS Margen
FROM simulacion.vw_ComparacionModelos ORDER BY Brier;
SELECT TOP (5) e.Nombre, CAST(x.Elo AS DECIMAL(6,1)) AS Elo FROM simulacion.Elo_Equipo AS x JOIN liga.Equipo AS e ON e.EquipoID = x.EquipoID ORDER BY x.Elo DESC;
GO
