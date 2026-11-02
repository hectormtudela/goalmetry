/* =============================================================================
   14_posiciones_curiosidades.sql
   Goalmetry - Ideas 3 y 5.
     3. analisis.vw_PosicionJornada: puesto de cada equipo tras cada jornada, con los mismos
        desempates que liga.vw_Clasificacion (puntos, diferencia de goles, goles a favor).
     5. analisis.Curiosidad y analisis.Remontada: se recalculan con
        analisis.usp_RecalcularCuriosidades (también al final de este script, y actualizar.ps1
        ejecuta este script después de cargar los datos).
   Las remontadas se reconstruyen con los minutos de los goles: no es el marcador real al
   descanso, sino cómo fue cambiando el resultado gol a gol.
   Ejecución:  sqlcmd -S localhost -E -C -b -i database\14_posiciones_curiosidades.sql
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

/* ---------- Idea 3 ---------- */
CREATE OR ALTER VIEW analisis.vw_PosicionJornada
AS
WITH T AS
(
    SELECT c.Jornada, e.EquipoID, e.Nombre,
           COALESCE(SUM(r.Puntos), 0) AS Pts, COALESCE(SUM(r.GF - r.GC), 0) AS DG, COALESCE(SUM(r.GF), 0) AS GF
    FROM (SELECT DISTINCT Jornada FROM analisis.vw_ResultadoEquipo) AS c
    CROSS JOIN liga.Equipo AS e
    LEFT JOIN analisis.vw_ResultadoEquipo AS r ON r.EquipoID = e.EquipoID AND r.Jornada <= c.Jornada
    GROUP BY c.Jornada, e.EquipoID, e.Nombre
)
SELECT Jornada, EquipoID, Nombre, Pts, DG, GF,
       RANK() OVER (PARTITION BY Jornada ORDER BY Pts DESC, DG DESC, GF DESC) AS Posicion,
       -- Para dibujar: una fila distinta por equipo aunque compartan puesto.
       ROW_NUMBER() OVER (PARTITION BY Jornada ORDER BY Pts DESC, DG DESC, GF DESC, Nombre) AS Fila
FROM T;
GO

/* ---------- Idea 5 ---------- */
IF OBJECT_ID(N'analisis.Curiosidad', N'U') IS NULL
CREATE TABLE analisis.Curiosidad
(
    CuriosidadID INT IDENTITY(1,1) NOT NULL,
    Categoria    VARCHAR(12)    NOT NULL,   -- Liga | Partido | Equipo | Remontada | Simulacion
    Titulo       NVARCHAR(60)   NOT NULL,
    Texto        NVARCHAR(400)  NOT NULL,
    CONSTRAINT PK_Curiosidad PRIMARY KEY (CuriosidadID)
);
IF OBJECT_ID(N'analisis.Remontada', N'U') IS NULL
CREATE TABLE analisis.Remontada
(
    PartidoID     INT NOT NULL,
    Jornada       TINYINT NOT NULL,
    EquipoID      INT NOT NULL,
    Titulo        NVARCHAR(150) NOT NULL,
    MaxDesventaja TINYINT NOT NULL,   -- la mayor desventaja que llegó a tener quien ganó
    CONSTRAINT PK_Remontada PRIMARY KEY (PartidoID)
);
GO

-- Marcador partido a partido, gol a gol. Dif > 0: va ganando el local.
CREATE OR ALTER VIEW analisis.vw_MarcadorGolAGol
AS
SELECT g.PartidoID, g.GolID, g.Minuto,
       SUM(CASE WHEN g.EquipoID = p.EquipoLocalID THEN 1 ELSE -1 END)
           OVER (PARTITION BY g.PartidoID ORDER BY g.Minuto, g.GolID ROWS UNBOUNDED PRECEDING) AS Dif
FROM liga.Gol AS g JOIN liga.Partido AS p ON p.PartidoID = g.PartidoID
WHERE p.Estado = 'Finalizado';
GO

CREATE OR ALTER PROCEDURE analisis.usp_RecalcularCuriosidades
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT p.PartidoID, j.Numero, CAST(p.GolesLocal AS INT) AS GL, CAST(p.GolesVisitante AS INT) AS GV,
           p.EquipoLocalID, p.EquipoVisitanteID, l.Nombre AS Local, v.Nombre AS Visitante,
           CONCAT(l.Nombre, N' ', p.GolesLocal, N'-', p.GolesVisitante, N' ', v.Nombre, N' (jornada ', j.Numero, N')') AS Titulo
    INTO #M
    FROM liga.Partido AS p
    JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
    JOIN liga.Equipo  AS l ON l.EquipoID = p.EquipoLocalID
    JOIN liga.Equipo  AS v ON v.EquipoID = p.EquipoVisitanteID
    WHERE p.Estado = 'Finalizado';

    DECLARE @C TABLE (Categoria VARCHAR(12), Titulo NVARCHAR(60), Texto NVARCHAR(400));

    IF EXISTS (SELECT 1 FROM #M)
    BEGIN
        INSERT @C SELECT 'Liga', N'Goles', CONCAT(N'En ', COUNT(*), N' partidos se han marcado ', SUM(GL + GV), N' goles: ', FORMAT(SUM(GL + GV) * 1.0 / COUNT(*), 'N2', 'es-ES'), N' por partido.') FROM #M;
        INSERT @C SELECT 'Liga', N'Jugar en casa', CONCAT(N'Los locales han ganado ', SUM(CASE WHEN GL > GV THEN 1 ELSE 0 END), N' de ', COUNT(*), N' partidos, y los visitantes, ', SUM(CASE WHEN GL < GV THEN 1 ELSE 0 END), N'.') FROM #M;
        INSERT @C SELECT 'Liga', N'Empates', CONCAT(N'Ha habido ', SUM(CASE WHEN GL = GV THEN 1 ELSE 0 END), N' empates, y ', SUM(CASE WHEN GL + GV = 0 THEN 1 ELSE 0 END), N' de ellos han acabado 0-0.') FROM #M;
        INSERT @C SELECT 'Partido', N'Más goles en un partido', CONCAT(MAX(GL + GV), N' goles: ', (SELECT STRING_AGG(Titulo, N'; ') FROM #M WHERE GL + GV = (SELECT MAX(GL + GV) FROM #M)), N'.') FROM #M;
        INSERT @C SELECT 'Partido', N'Mayor goleada', CONCAT(N'Por ', MAX(ABS(GL - GV)), N' goles de diferencia: ', (SELECT STRING_AGG(Titulo, N'; ') FROM #M WHERE ABS(GL - GV) = (SELECT MAX(ABS(GL - GV)) FROM #M)), N'.') FROM #M;

        SELECT g.Minuto, g.Anotador, m.Titulo, g.Tipo, g.PartidoID INTO #G FROM liga.Gol AS g JOIN #M AS m ON m.PartidoID = g.PartidoID;
        IF EXISTS (SELECT 1 FROM #G)
        BEGIN
            INSERT @C SELECT 'Partido', N'El gol más tardío', CONCAT(N'Minuto ', MAX(Minuto), N': ', (SELECT STRING_AGG(CONCAT(Anotador, N', en el ', Titulo), N'; ') FROM #G WHERE Minuto = (SELECT MAX(Minuto) FROM #G)), N'.') FROM #G;
            INSERT @C SELECT 'Partido', N'El gol más madrugador', CONCAT(N'Minuto ', MIN(Minuto), N': ', (SELECT STRING_AGG(CONCAT(Anotador, N', en el ', Titulo), N'; ') FROM #G WHERE Minuto = (SELECT MIN(Minuto) FROM #G)), N'.') FROM #G;
            INSERT @C SELECT 'Liga', N'Tres goles o más', CONCAT(N'Un mismo jugador ha marcado tres goles o más en un partido ', COUNT(*), N' veces.') FROM (SELECT PartidoID, Anotador FROM #G WHERE Tipo <> 'PropiaPuerta' GROUP BY PartidoID, Anotador HAVING COUNT(*) >= 3) AS x;
            INSERT @C SELECT 'Liga', N'En propia puerta', CONCAT(N'Goles en propia puerta esta temporada: ', COUNT(*), N'.') FROM #G WHERE Tipo = 'PropiaPuerta';
        END;

        INSERT @C SELECT TOP (1) 'Equipo', N'Especialista de penalti', CONCAT(Anotador, N' (', Equipo, N') ha marcado ', Penaltis, N' de penalti.') FROM liga.vw_MaximosGoleadores WHERE Penaltis > 0 ORDER BY Penaltis DESC, Goles DESC, Anotador;
        INSERT @C SELECT TOP (1) 'Equipo', N'Equipo más goleador', CONCAT(Equipo, N', con ', GF, N' goles.') FROM liga.vw_Clasificacion ORDER BY GF DESC, Equipo;
        INSERT @C SELECT TOP (1) 'Equipo', N'Equipo menos goleado', CONCAT(Equipo, N', con ', GC, N' goles en contra.') FROM liga.vw_Clasificacion ORDER BY GC, Equipo;
        INSERT @C SELECT TOP (1) 'Equipo', N'Equipo que más empata', CONCAT(Equipo, N', con ', E, N' empates en ', PJ, N' partidos.') FROM liga.vw_Clasificacion ORDER BY E DESC, Equipo;
        INSERT @C SELECT TOP (1) 'Liga', N'Jornada con más goles', CONCAT(N'La jornada ', Numero, N', con ', SUM(GL + GV), N' goles.') FROM #M GROUP BY Numero ORDER BY SUM(GL + GV) DESC, Numero;
        INSERT @C SELECT TOP (1) 'Liga', N'Árbitro con más partidos', CONCAT(a.Nombre, N', con ', COUNT(*), N' partidos.') FROM liga.Partido AS p JOIN liga.Arbitro AS a ON a.ArbitroID = p.ArbitroPrincipalID WHERE p.Estado = 'Finalizado' GROUP BY a.Nombre ORDER BY COUNT(*) DESC, a.Nombre;

        -- Racha invicta más larga: se numera cada derrota y se cuentan los partidos entre derrotas.
        ;WITH O AS
        (
            SELECT r.EquipoID, r.Resultado,
                   SUM(CASE WHEN r.Resultado = 'D' THEN 1 ELSE 0 END) OVER (PARTITION BY r.EquipoID ORDER BY r.FechaHora, r.Jornada ROWS UNBOUNDED PRECEDING) AS Grupo
            FROM analisis.vw_ResultadoEquipo AS r
        ),
        Rachas AS (SELECT EquipoID, Grupo, SUM(CASE WHEN Resultado <> 'D' THEN 1 ELSE 0 END) AS Partidos FROM O GROUP BY EquipoID, Grupo)
        INSERT @C
        SELECT 'Equipo', N'Racha invicta más larga',
               CONCAT(STRING_AGG(e.Nombre, N', ') WITHIN GROUP (ORDER BY e.Nombre), N': ', MAX(t.Partidos), N' partidos seguidos sin perder.')
        FROM Rachas AS t JOIN liga.Equipo AS e ON e.EquipoID = t.EquipoID
        WHERE t.Partidos = (SELECT MAX(Partidos) FROM Rachas) AND t.Partidos > 0
        HAVING COUNT(*) > 0;

        INSERT @C SELECT 'Simulacion', N'Fútbol sin parar',
               CONCAT(N'Cada simulación juega ', FORMAT((380 - COUNT(*)) * 10000, 'N0', 'es-ES'), N' partidos. A 90 minutos cada uno, serían ',
                      FORMAT((380 - COUNT(*)) * 10000.0 * 90 / 60 / 24 / 365, 'N0', 'es-ES'), N' años de fútbol sin parar.')
        FROM #M;
    END;

    -- Remontadas: quien ganó llegó a ir perdiendo en algún momento.
    SELECT m.PartidoID, m.Numero, m.Titulo,
           CASE WHEN m.GL > m.GV THEN m.EquipoLocalID ELSE m.EquipoVisitanteID END AS EquipoID,
           CASE WHEN m.GL > m.GV THEN m.Local ELSE m.Visitante END AS Ganador,
           CASE WHEN m.GL > m.GV THEN -d.MinDif ELSE d.MaxDif END AS Desventaja
    INTO #R
    FROM #M AS m
    CROSS APPLY (SELECT MIN(x.Dif) AS MinDif, MAX(x.Dif) AS MaxDif FROM analisis.vw_MarcadorGolAGol AS x WHERE x.PartidoID = m.PartidoID) AS d
    WHERE (m.GL > m.GV AND d.MinDif < 0) OR (m.GL < m.GV AND d.MaxDif > 0);

    IF EXISTS (SELECT 1 FROM #R)
        INSERT @C
        SELECT 'Remontada', N'Remontadas',
               CONCAT(N'Se han remontado ', COUNT(*), N' partidos, reconstruyendo el resultado con los minutos de los goles. La mayor desventaja remontada: ',
                      MAX(Desventaja), CASE WHEN MAX(Desventaja) = 1 THEN N' gol' ELSE N' goles' END,
                      N' (la última: ', (SELECT TOP (1) Titulo FROM #R ORDER BY Desventaja DESC, Numero DESC), N').')
        FROM #R;

    BEGIN TRANSACTION;
        DELETE FROM analisis.Curiosidad;
        INSERT INTO analisis.Curiosidad (Categoria, Titulo, Texto) SELECT Categoria, Titulo, Texto FROM @C WHERE Texto IS NOT NULL;
        DELETE FROM analisis.Remontada;
        INSERT INTO analisis.Remontada (PartidoID, Jornada, EquipoID, Titulo, MaxDesventaja) SELECT PartidoID, Numero, EquipoID, Titulo, Desventaja FROM #R;
    COMMIT TRANSACTION;
END;
GO

EXEC analisis.usp_RecalcularCuriosidades;
GO

SELECT COUNT(*) AS Curiosidades, (SELECT COUNT(*) FROM analisis.Remontada) AS Remontadas FROM analisis.Curiosidad;
GO
