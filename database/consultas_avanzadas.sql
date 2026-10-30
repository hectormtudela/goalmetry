/* =============================================================================
   consultas_avanzadas.sql
   Goalmetry (DP-800, Práctica 09) - Bloque A
   Consultas T-SQL avanzadas (solo lectura, no modifican datos):
     1. CTE + window functions: puntos acumulados y posición tras cada jornada.
     2. Window functions: goles por 90 minutos (>= 270 minutos jugados).
     3. JSON: ficha de partido con sus goles (JSON_OBJECT + JSON_ARRAYAGG) y lectura con OPENJSON.
     4. REGEXP_LIKE / REGEXP_REPLACE: validación de DNI, teléfonos y emails de abonados.
     5. EDIT_DISTANCE: búsqueda aproximada de nombres ("Mbape") y candidatos para los
        goles sin JugadorID. Solo se MUESTRAN; no se cambia ningún dato.
     6. Subconsulta correlacionada: jugadores por encima de la media goleadora de su equipo.
     7. Jugador.Goles (matchscan) frente a COUNT de liga.Gol (futbolfantasy): se muestra, no se corrige.
   Ejecución:  sqlcmd -S localhost -E -C -b -i database\consultas_avanzadas.sql
   Requisitos: nivel de compatibilidad 170 y PREVIEW_FEATURES = ON (ambos en 01_create_database.sql).
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

/* ===================== 1. Puntos acumulados y posición por jornada ===================== */
PRINT N'=== 1. Posición de cada equipo tras cada jornada (CTE + SUM/RANK OVER) ===';

DROP TABLE IF EXISTS #Posiciones;

WITH PorPartido AS
(
    -- Un registro por equipo y partido finalizado.
    -- CAST a INT: los goles son TINYINT (0-255) y GF - GC negativo desbordaría.
    SELECT j.Numero, r.EquipoID, CAST(r.GF AS INT) AS GF, CAST(r.GC AS INT) AS GC,
           CASE WHEN r.GF > r.GC THEN 3 WHEN r.GF = r.GC THEN 1 ELSE 0 END AS Pts
    FROM liga.Partido AS p
    JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
    CROSS APPLY (VALUES (p.EquipoLocalID,     p.GolesLocal,     p.GolesVisitante),
                        (p.EquipoVisitanteID, p.GolesVisitante, p.GolesLocal)) AS r (EquipoID, GF, GC)
    WHERE p.Estado = 'Finalizado'
),
Rejilla AS
(
    -- Equipo x jornada: si el partido no se ha jugado (J10), suma 0 y la posición se arrastra
    SELECT e.EquipoID, e.Nombre, j.Numero,
           ISNULL(pp.Pts, 0) AS Pts,
           ISNULL(pp.GF, 0)  AS GF,
           ISNULL(pp.GC, 0)  AS GC
    FROM liga.Equipo  AS e
    CROSS JOIN liga.Jornada AS j
    LEFT JOIN PorPartido AS pp ON pp.EquipoID = e.EquipoID AND pp.Numero = j.Numero
),
Acumulado AS
(
    SELECT EquipoID, Nombre, Numero,
           SUM(Pts)     OVER (PARTITION BY EquipoID ORDER BY Numero ROWS UNBOUNDED PRECEDING) AS PtsAcum,
           SUM(GF - GC) OVER (PARTITION BY EquipoID ORDER BY Numero ROWS UNBOUNDED PRECEDING) AS DGAcum,
           SUM(GF)      OVER (PARTITION BY EquipoID ORDER BY Numero ROWS UNBOUNDED PRECEDING) AS GFAcum
    FROM Rejilla
)
SELECT EquipoID, Nombre, Numero, PtsAcum, DGAcum, GFAcum,
       RANK() OVER (PARTITION BY Numero ORDER BY PtsAcum DESC, DGAcum DESC, GFAcum DESC) AS Pos
INTO #Posiciones
FROM Acumulado;

-- Tabla "pivotada": una fila por equipo y una columna por jornada
SELECT Nombre AS Equipo,
       MAX(CASE WHEN Numero = 1 THEN Pos ELSE 0 END) AS J1,
       MAX(CASE WHEN Numero = 2 THEN Pos ELSE 0 END) AS J2,
       MAX(CASE WHEN Numero = 3 THEN Pos ELSE 0 END) AS J3,
       MAX(CASE WHEN Numero = 4 THEN Pos ELSE 0 END) AS J4,
       MAX(CASE WHEN Numero = 5 THEN Pos ELSE 0 END) AS J5,
       MAX(CASE WHEN Numero = 6 THEN Pos ELSE 0 END) AS J6,
       MAX(CASE WHEN Numero = 7 THEN Pos ELSE 0 END) AS J7,
       MAX(CASE WHEN Numero = 8 THEN Pos ELSE 0 END) AS J8,
       MAX(CASE WHEN Numero = 9 THEN Pos ELSE 0 END) AS J9,
       MAX(CASE WHEN Numero = 10 THEN Pos ELSE 0 END) AS J10,
       MAX(PtsAcum)                            AS Pts,
       MIN(Pos)                                AS MejorPos,
       MAX(Pos)                                AS PeorPos
FROM #Posiciones
GROUP BY EquipoID, Nombre
ORDER BY J10, Equipo;

-- LAG: subidas y bajadas de la J8 a la J9 (última jornada completa)
PRINT N'--- Mayores cambios de posición de la J8 a la J9 (LAG) ---';
WITH Cambios AS
(
    SELECT Nombre, Numero, Pos,
           LAG(Pos) OVER (PARTITION BY EquipoID ORDER BY Numero) AS PosAnterior
    FROM #Posiciones
)
SELECT TOP (5) WITH TIES Nombre AS Equipo, PosAnterior AS PosJ8, Pos AS PosJ9,
       PosAnterior - Pos AS Puestos   -- positivo = sube
FROM Cambios
WHERE Numero = 9
ORDER BY ABS(PosAnterior - Pos) DESC;

DROP TABLE #Posiciones;
GO

/* ===================== 2. Goles por 90 minutos ===================== */
PRINT N'=== 2. Goles por 90 minutos (mínimo 270 minutos, datos de liga.Jugador) ===';
WITH Ratio AS
(
    SELECT j.Nombre, e.Nombre AS Equipo, j.Posicion, j.Goles, j.MinutosJugados,
           CAST(j.Goles * 90.0 / j.MinutosJugados AS DECIMAL(4,2)) AS GolesPor90
    FROM liga.Jugador AS j
    JOIN liga.Equipo  AS e ON e.EquipoID = j.EquipoID
    WHERE j.MinutosJugados >= 270
      AND j.Goles > 0
)
SELECT TOP (10) WITH TIES
       RANK() OVER (ORDER BY GolesPor90 DESC)                       AS Rk,
       Nombre, Equipo, Posicion, Goles, MinutosJugados, GolesPor90,
       RANK() OVER (PARTITION BY Posicion ORDER BY GolesPor90 DESC) AS RkEnPosicion,
       CAST(PERCENT_RANK() OVER (ORDER BY GolesPor90) * 100 AS DECIMAL(5,1)) AS Percentil
FROM Ratio
ORDER BY Rk, Nombre;
GO

/* ===================== 3. JSON ===================== */
PRINT N'=== 3. Ficha JSON del partido con más goles (JSON_OBJECT + JSON_ARRAYAGG) ===';
DECLARE @PartidoID INT =
    (SELECT TOP (1) PartidoID FROM liga.Partido
     WHERE Estado = 'Finalizado'
     ORDER BY GolesLocal + GolesVisitante DESC, PartidoID);

DECLARE @Ficha NVARCHAR(MAX) =
(
    SELECT CONVERT(NVARCHAR(MAX), JSON_OBJECT(
               'partidoId' : p.PartidoID,
               'jornada'   : j.Numero,
               'fecha'     : CONVERT(VARCHAR(16), p.FechaHora, 126),
               'estadio'   : s.Nombre,
               'local'     : el.Nombre,
               'visitante' : ev.Nombre,
               'marcador'  : CONCAT(p.GolesLocal, '-', p.GolesVisitante),
               'goles'     : (SELECT JSON_ARRAYAGG(
                                        JSON_OBJECT('minuto'   : g.Minuto,
                                                    'anotador' : g.Anotador,
                                                    'equipo'   : eg.Nombre,
                                                    'tipo'     : g.Tipo)
                                        ORDER BY g.Minuto RETURNING JSON)
                              FROM liga.Gol    AS g
                              JOIN liga.Equipo AS eg ON eg.EquipoID = g.EquipoID
                              WHERE g.PartidoID = p.PartidoID)
               RETURNING JSON))   -- json nativo -> NVARCHAR(MAX); 'goles' se anida como array, no como texto
    FROM liga.Partido AS p
    JOIN liga.Jornada AS j  ON j.JornadaID = p.JornadaID
    JOIN liga.Estadio AS s  ON s.EstadioID = p.EstadioID
    JOIN liga.Equipo  AS el ON el.EquipoID = p.EquipoLocalID
    JOIN liga.Equipo  AS ev ON ev.EquipoID = p.EquipoVisitanteID
    WHERE p.PartidoID = @PartidoID
);

SELECT ISJSON(@Ficha) AS EsJSONValido, LEN(@Ficha) AS Caracteres;
PRINT @Ficha;   -- PRINT para verlo entero (sqlcmd corta las columnas largas en la salida)

PRINT N'--- Lectura de vuelta con OPENJSON (JSON -> filas) ---';
SELECT JSON_VALUE(@Ficha, '$.local') + N' ' + JSON_VALUE(@Ficha, '$.marcador') + N' '
       + JSON_VALUE(@Ficha, '$.visitante') AS Partido,
       g.minuto, g.anotador, g.equipo, g.tipo
FROM OPENJSON(@Ficha, '$.goles')
     WITH (minuto   TINYINT       '$.minuto',
           anotador NVARCHAR(100) '$.anotador',
           equipo   NVARCHAR(60)  '$.equipo',
           tipo     VARCHAR(12)   '$.tipo') AS g;
GO

/* ===================== 4. Expresiones regulares ===================== */
PRINT N'=== 4. REGEXP_LIKE: validación de los datos de abonados ===';
-- DNI: 8 cifras + letra, y la letra debe ser la de control (número mod 23).
-- Móvil español: 6xx/7xx, con o sin +34 y con o sin espacios.
SELECT COUNT(*) AS Abonados,
       SUM(CASE WHEN REGEXP_LIKE(Documento, '^[0-9]{8}[A-Z]$') THEN 1 ELSE 0 END) AS DNIFormatoOK,
       SUM(CASE WHEN REGEXP_LIKE(Documento, '^[0-9]{8}[A-Z]$')
                 AND RIGHT(Documento, 1) = SUBSTRING('TRWAGMYFPDXBNJZSQVHLCKE',
                                                    CAST(LEFT(Documento, 8) AS INT) % 23 + 1, 1)
                THEN 1 ELSE 0 END)                                                AS DNILetraOK,
       SUM(CASE WHEN REGEXP_LIKE(Telefono, '^(\+34 ?)?[67][0-9]{2} ?[0-9]{3} ?[0-9]{3}$')
                THEN 1 ELSE 0 END)                                                AS TelefonoOK,
       SUM(CASE WHEN Telefono IS NULL THEN 1 ELSE 0 END)                          AS TelefonoNulo,
       SUM(CASE WHEN REGEXP_LIKE(Email, '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$', 'i')
                THEN 1 ELSE 0 END)                                                AS EmailOK
FROM ventas.Abonado;

PRINT N'--- Formatos de teléfono encontrados y normalización con REGEXP_REPLACE ---';
SELECT REGEXP_REPLACE(REGEXP_REPLACE(Telefono, '[0-9]', '9'), '9+', '9…') AS Patron,  -- forma del número
       COUNT(*)                                                           AS Abonados,
       MIN(Telefono)                                                      AS Ejemplo,
       '+34' + RIGHT(REGEXP_REPLACE(MIN(Telefono), '[^0-9]', ''), 9)      AS EjemploNormalizado
FROM ventas.Abonado
WHERE Telefono IS NOT NULL
GROUP BY REGEXP_REPLACE(REGEXP_REPLACE(Telefono, '[0-9]', '9'), '9+', '9…')
ORDER BY Abonados DESC;
GO

/* ===================== 5. Búsqueda aproximada con EDIT_DISTANCE ===================== */
PRINT N'=== 5a. ¿Quién es "Mbape"? Jugadores más parecidos (EDIT_DISTANCE, preview) ===';
DECLARE @Buscado NVARCHAR(100) = N'Mbape';

-- Se compara con la última palabra del nombre ("Kylian Mbappé" -> "Mbappé"): la gente
-- suele buscar por apellido, y contra el nombre completo la distancia sale inflada.
SELECT TOP (5) j.Nombre, e.Nombre AS Equipo, a.Apellido,
       EDIT_DISTANCE(@Buscado, a.Apellido)            AS Distancia,     -- nº de ediciones
       EDIT_DISTANCE_SIMILARITY(@Buscado, a.Apellido) AS Similitud      -- 0-100
FROM liga.Jugador AS j
JOIN liga.Equipo  AS e ON e.EquipoID = j.EquipoID
CROSS APPLY (VALUES (REVERSE(LEFT(REVERSE(j.Nombre), CHARINDEX(N' ', REVERSE(j.Nombre) + N' ') - 1))))
            AS a (Apellido)
ORDER BY Distancia, Similitud DESC, j.Nombre;

PRINT N'--- 5b. Goles sin JugadorID: candidatos de su mismo equipo (SOLO se muestran) ---';
SELECT g.GolID, g.Anotador, e.Nombre AS Equipo,
       c.Nombre AS Candidato, c.Distancia, c.Similitud
FROM liga.Gol    AS g
JOIN liga.Equipo AS e ON e.EquipoID = g.EquipoID
OUTER APPLY
(
    SELECT TOP (2) j.Nombre,
           EDIT_DISTANCE(g.Anotador, j.Nombre)            AS Distancia,
           EDIT_DISTANCE_SIMILARITY(g.Anotador, j.Nombre) AS Similitud
    FROM liga.Jugador AS j
    WHERE j.EquipoID = g.EquipoID
    ORDER BY EDIT_DISTANCE(g.Anotador, j.Nombre), j.Nombre
) AS c
WHERE g.JugadorID IS NULL
ORDER BY g.GolID, c.Distancia;
GO

/* ===================== 6. Subconsulta correlacionada ===================== */
PRINT N'=== 6. Jugadores por encima de la media goleadora de su equipo ===';
SELECT TOP (15) WITH TIES
       j.Nombre, e.Nombre AS Equipo, j.Goles,
       CAST((SELECT AVG(CAST(j2.Goles AS DECIMAL(6,2)))
             FROM liga.Jugador AS j2
             WHERE j2.EquipoID = j.EquipoID) AS DECIMAL(4,2))                AS MediaEquipo,
       CAST(100.0 * j.Goles / NULLIF((SELECT SUM(j3.Goles)
                                      FROM liga.Jugador AS j3
                                      WHERE j3.EquipoID = j.EquipoID), 0)
            AS DECIMAL(5,1))                                                  AS PctGolesEquipo
FROM liga.Jugador AS j
JOIN liga.Equipo  AS e ON e.EquipoID = j.EquipoID
WHERE j.Goles > (SELECT AVG(CAST(j2.Goles AS DECIMAL(6,2)))    -- se evalúa para cada fila de j
                 FROM liga.Jugador AS j2
                 WHERE j2.EquipoID = j.EquipoID)
ORDER BY PctGolesEquipo DESC, j.Nombre;

SELECT COUNT(*) AS JugadoresPorEncimaDeSuMedia
FROM liga.Jugador AS j
WHERE j.Goles > (SELECT AVG(CAST(j2.Goles AS DECIMAL(6,2)))
                 FROM liga.Jugador AS j2
                 WHERE j2.EquipoID = j.EquipoID);
GO

/* ===================== 7. Dos fuentes de goles ===================== */
PRINT N'=== 7. Jugador.Goles (matchscan) frente a liga.Gol (futbolfantasy) ===';
SELECT (SELECT SUM(Goles) FROM liga.Jugador)                                   AS SumaJugadorGoles,
       (SELECT COUNT(*) FROM liga.Gol)                                         AS FilasGol,
       (SELECT COUNT(*) FROM liga.Gol WHERE Tipo = 'PropiaPuerta')             AS PropiaPuerta,
       (SELECT COUNT(*) FROM liga.Gol WHERE Tipo <> 'PropiaPuerta' AND JugadorID IS NULL) AS SinJugadorID,
       (SELECT COUNT(*) FROM liga.Gol WHERE Tipo <> 'PropiaPuerta' AND JugadorID IS NOT NULL) AS GolVinculados;

PRINT N'--- Jugadores en los que no coinciden las dos fuentes ---';
-- GolesActasHastaUlt: goles de las actas solo hasta la jornada a la que llegan los totales
-- de matchscan (Jugador.UltimaJornada). Si la diferencia desaparece, el descuadre se debe
-- al corte temporal de cada fuente y no a un error de datos.
WITH GolesActa AS
(
    SELECT g.JugadorID,
           COUNT(*)                                             AS GolesActas,
           SUM(CASE WHEN jo.Numero <= ju.UltimaJornada THEN 1 ELSE 0 END) AS GolesActasHastaUlt
    FROM liga.Gol     AS g
    JOIN liga.Partido AS p  ON p.PartidoID  = g.PartidoID
    JOIN liga.Jornada AS jo ON jo.JornadaID = p.JornadaID
    JOIN liga.Jugador AS ju ON ju.JugadorID = g.JugadorID
    WHERE g.Tipo <> 'PropiaPuerta'
    GROUP BY g.JugadorID
)
SELECT j.Nombre, e.Nombre AS Equipo, j.UltimaJornada,
       j.Goles                                  AS GolesMatchscan,
       ISNULL(ga.GolesActas, 0)                 AS GolesActas,
       ISNULL(ga.GolesActas, 0) - j.Goles       AS Diferencia,
       ISNULL(ga.GolesActasHastaUlt, 0)         AS GolesActasHastaUlt,
       ISNULL(ga.GolesActasHastaUlt, 0) - j.Goles AS DiferenciaHastaUlt
FROM liga.Jugador     AS j
JOIN liga.Equipo      AS e  ON e.EquipoID = j.EquipoID
LEFT JOIN GolesActa   AS ga ON ga.JugadorID = j.JugadorID
WHERE ISNULL(ga.GolesActas, 0) <> j.Goles
ORDER BY ABS(ISNULL(ga.GolesActas, 0) - j.Goles) DESC, j.Nombre;
GO
