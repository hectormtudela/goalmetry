/* =============================================================================
   11_minutos_gol.sql
   Goalmetry - Idea 2: mapa de minutos de gol, por tramos de 15 minutos.
   Los goles en propia puerta cuentan para el equipo beneficiado (Gol.EquipoID), igual que
   en el marcador. El descuento de cada parte cae en el tramo de su minuto registrado.
   Ejecución:  sqlcmd -S localhost -E -C -b -i database\11_minutos_gol.sql
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

CREATE OR ALTER VIEW analisis.vw_GolPorTramo
AS
SELECT r.EquipoID, t.Tramo, g.GolID, CASE WHEN g.EquipoID = r.EquipoID THEN 1 ELSE 0 END AS AFavor
FROM liga.Gol AS g
JOIN analisis.vw_ResultadoEquipo AS r ON r.PartidoID = g.PartidoID
CROSS APPLY (SELECT LEAST((CAST(g.Minuto AS INT) - 1) / 15, 5) AS Tramo) AS t;
GO

CREATE OR ALTER PROCEDURE analisis.usp_MinutosGol
    @EquipoID INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.value AS Tramo, n.Etiqueta,
           COALESCE(SUM(CASE WHEN g.AFavor = 1 THEN 1 END), 0) AS AFavor,
           COALESCE(SUM(CASE WHEN g.AFavor = 0 THEN 1 END), 0) AS EnContra
    FROM GENERATE_SERIES(0, 5) AS s
    CROSS APPLY (SELECT CHOOSE(s.value + 1, N'1-15', N'16-30', N'31-45', N'46-60', N'61-75', N'76-90+') AS Etiqueta) AS n
    LEFT JOIN analisis.vw_GolPorTramo AS g ON g.Tramo = s.value AND g.EquipoID = @EquipoID
    GROUP BY s.value, n.Etiqueta
    ORDER BY s.value;
END;
GO

IF DATABASE_PRINCIPAL_ID(N'rol_web_publico') IS NOT NULL
    GRANT EXECUTE ON OBJECT::analisis.usp_MinutosGol TO rol_web_publico;
GO
