/* =============================================================================
   04_views_functions.sql
   Proyecto LigaDB (DP-800, Práctica 09) - Bloque A
   Vistas y funciones de consulta:
     - liga.vw_Clasificacion      : tabla de clasificación (CTE + RANK()).
     - liga.vw_MaximosGoleadores  : ranking de goleadores a partir de liga.Gol.
     - liga.fn_PuntosEquipo       : puntos de un equipo hasta una jornada dada.
   Ejecución:  sqlcmd -S localhost -E -C -b -i database\04_views_functions.sql
   Idempotente: CREATE OR ALTER.
   Solo cuentan los partidos con Estado = 'Finalizado' (la J10 está incompleta).
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

/* ---------- liga.vw_Clasificacion ----------
   Cada partido finalizado se "despliega" en dos filas (local y visitante) con
   CROSS APPLY (VALUES ...), se agregan por equipo y se ordenan con RANK().
   Desempate simplificado: puntos, diferencia de goles y goles a favor.
   (El reglamento real usa primero el enfrentamiento directo; se explica en la memoria.) */
CREATE OR ALTER VIEW liga.vw_Clasificacion
AS
WITH Resultados AS
(
    SELECT j.TemporadaID,
           r.EquipoID,
           r.GF,
           r.GC
    FROM liga.Partido AS p
    JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
    CROSS APPLY (VALUES (p.EquipoLocalID,     p.GolesLocal,     p.GolesVisitante),
                        (p.EquipoVisitanteID, p.GolesVisitante, p.GolesLocal)) AS r (EquipoID, GF, GC)
    WHERE p.Estado = 'Finalizado'
),
Totales AS
(
    SELECT TemporadaID,
           EquipoID,
           COUNT(*)                                  AS PJ,
           SUM(CASE WHEN GF > GC  THEN 1 ELSE 0 END) AS G,
           SUM(CASE WHEN GF = GC  THEN 1 ELSE 0 END) AS E,
           SUM(CASE WHEN GF < GC  THEN 1 ELSE 0 END) AS P,
           SUM(CAST(GF AS INT))                      AS GF,
           SUM(CAST(GC AS INT))                      AS GC
    FROM Resultados
    GROUP BY TemporadaID, EquipoID
)
SELECT RANK() OVER (PARTITION BY t.TemporadaID
                    ORDER BY t.G * 3 + t.E DESC, t.GF - t.GC DESC, t.GF DESC) AS Posicion,
       t.TemporadaID,
       t.EquipoID,
       e.Nombre                AS Equipo,
       t.PJ, t.G, t.E, t.P,
       t.GF, t.GC,
       t.GF - t.GC             AS DG,
       t.G * 3 + t.E           AS Pts
FROM Totales     AS t
JOIN liga.Equipo AS e ON e.EquipoID = t.EquipoID;
GO

/* ---------- liga.vw_MaximosGoleadores ----------
   Se calcula desde liga.Gol (fuente: actas de futbolfantasy), no desde Jugador.Goles.
   Se excluyen los goles en propia puerta (no son del anotador). Se agrupa también por
   Anotador para no perder los goles con JugadorID NULL (anotador fuera de liga.Jugador). */
CREATE OR ALTER VIEW liga.vw_MaximosGoleadores
AS
SELECT RANK() OVER (ORDER BY COUNT(*) DESC)                       AS Posicion,
       g.JugadorID,
       g.Anotador,
       e.Nombre                                                   AS Equipo,
       COUNT(*)                                                   AS Goles,
       SUM(CASE WHEN g.Tipo = 'Penalti' THEN 1 ELSE 0 END)        AS Penaltis,
       COUNT(DISTINCT g.PartidoID)                                AS PartidosMarcando
FROM liga.Gol    AS g
JOIN liga.Equipo AS e ON e.EquipoID = g.EquipoID
WHERE g.Tipo <> 'PropiaPuerta'
GROUP BY g.JugadorID, g.Anotador, e.Nombre;
GO

/* ---------- liga.fn_PuntosEquipo ----------
   Puntos de @EquipoID en los partidos finalizados de las jornadas 1..@HastaJornada.
   Supone una sola temporada cargada (2026-27). Escalar sin acceso a tablas temporales
   ni efectos secundarios, así que SQL Server 2019+ puede "inlinearla" (Scalar UDF Inlining). */
CREATE OR ALTER FUNCTION liga.fn_PuntosEquipo
(
    @EquipoID     INT,
    @HastaJornada TINYINT
)
RETURNS INT
AS
BEGIN
    RETURN
    (
        SELECT ISNULL(SUM(CASE WHEN r.GF > r.GC THEN 3
                               WHEN r.GF = r.GC THEN 1
                               ELSE 0 END), 0)
        FROM liga.Partido AS p
        JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
        CROSS APPLY (VALUES (p.EquipoLocalID,     p.GolesLocal,     p.GolesVisitante),
                            (p.EquipoVisitanteID, p.GolesVisitante, p.GolesLocal)) AS r (EquipoID, GF, GC)
        WHERE p.Estado   = 'Finalizado'
          AND j.Numero  <= @HastaJornada
          AND r.EquipoID = @EquipoID
    );
END;
GO

/* ============================== Comprobación ============================== */
PRINT N'--- Clasificación actual ---';
SELECT Posicion, Equipo, PJ, G, E, P, GF, GC, DG, Pts
FROM liga.vw_Clasificacion
ORDER BY Posicion, Equipo;

PRINT N'--- Top 10 goleadores (liga.Gol, sin propia puerta) ---';
SELECT TOP (10) WITH TIES Posicion, Anotador, Equipo, Goles, Penaltis, PartidosMarcando,
       CASE WHEN JugadorID IS NULL THEN N'sin JugadorID' ELSE N'' END AS Nota
FROM liga.vw_MaximosGoleadores
ORDER BY Posicion, Anotador;

PRINT N'--- fn_PuntosEquipo: evolución del líder por jornada ---';
DECLARE @Lider INT = (SELECT TOP (1) EquipoID FROM liga.vw_Clasificacion ORDER BY Posicion, Equipo);
SELECT e.Nombre AS Equipo, j.Numero AS HastaJornada, liga.fn_PuntosEquipo(@Lider, j.Numero) AS Pts
FROM liga.Jornada AS j
JOIN liga.Equipo  AS e ON e.EquipoID = @Lider
ORDER BY j.Numero;

PRINT N'--- Comprobaciones cruzadas (todas deben ser 0) ---';
SELECT
    -- 1) La función, hasta la última jornada, da los mismos puntos que la vista.
    (SELECT COUNT(*) FROM liga.vw_Clasificacion AS c
     WHERE liga.fn_PuntosEquipo(c.EquipoID, 38) <> c.Pts)                                  AS PuntosDistintos,
    -- 2) Partidos jugados en la vista = 2 x partidos finalizados.
    (SELECT SUM(PJ) FROM liga.vw_Clasificacion)
      - 2 * (SELECT COUNT(*) FROM liga.Partido WHERE Estado = 'Finalizado')                 AS DescuadrePJ,
    -- 3) Goles a favor totales = goles de los marcadores.
    (SELECT SUM(GF) FROM liga.vw_Clasificacion)
      - (SELECT SUM(CAST(GolesLocal AS INT) + GolesVisitante) FROM liga.Partido
         WHERE Estado = 'Finalizado')                                                        AS DescuadreGoles,
    -- 4) Victorias totales = derrotas totales (cada partido decidido suma una de cada).
    (SELECT SUM(G) - SUM(P) FROM liga.vw_Clasificacion)                                     AS DescuadreGP,
    -- 5) Equipos sin fila en la clasificación (todos han jugado al menos un partido).
    (SELECT COUNT(*) FROM liga.Equipo AS e
     WHERE NOT EXISTS (SELECT 1 FROM liga.vw_Clasificacion AS c WHERE c.EquipoID = e.EquipoID)) AS EquiposSinFila;
GO
