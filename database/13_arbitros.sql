/* =============================================================================
   13_arbitros.sql
   Goalmetry - Idea 6: perfil de árbitro. Solo datos descriptivos de los partidos que ha
   dirigido, junto a la media de la liga. Con tan pocos partidos, las diferencias no
   permiten sacar conclusiones sobre ningún árbitro.
   Los penaltis son los que acabaron en gol: los datos no recogen los fallados.
   Ejecución:  sqlcmd -S localhost -E -C -b -i database\13_arbitros.sql
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

CREATE OR ALTER VIEW analisis.vw_Arbitro
AS
SELECT a.ArbitroID, a.Nombre, x.Partidos, x.VictoriasLocales, x.Empates, x.VictoriasVisitantes, x.Goles, COALESCE(g.Penaltis, 0) AS PenaltisMarcados
FROM liga.Arbitro AS a
CROSS APPLY (SELECT COUNT(*) AS Partidos,
                    COALESCE(SUM(CASE WHEN p.GolesLocal > p.GolesVisitante THEN 1 ELSE 0 END), 0) AS VictoriasLocales,
                    COALESCE(SUM(CASE WHEN p.GolesLocal = p.GolesVisitante THEN 1 ELSE 0 END), 0) AS Empates,
                    COALESCE(SUM(CASE WHEN p.GolesLocal < p.GolesVisitante THEN 1 ELSE 0 END), 0) AS VictoriasVisitantes,
                    COALESCE(SUM(CAST(p.GolesLocal AS INT) + p.GolesVisitante), 0) AS Goles
             FROM liga.Partido AS p WHERE p.ArbitroPrincipalID = a.ArbitroID AND p.Estado = 'Finalizado') AS x
OUTER APPLY (SELECT COUNT(*) AS Penaltis FROM liga.Gol AS g JOIN liga.Partido AS p ON p.PartidoID = g.PartidoID
             WHERE p.ArbitroPrincipalID = a.ArbitroID AND p.Estado = 'Finalizado' AND g.Tipo = 'Penalti') AS g;
GO

CREATE OR ALTER VIEW analisis.vw_MediaLigaArbitros
AS
SELECT SUM(Partidos) AS Partidos,
       100.0 * SUM(VictoriasLocales) / NULLIF(SUM(Partidos), 0) AS PctLocal,
       1.0 * SUM(Goles) / NULLIF(SUM(Partidos), 0) AS GolesPorPartido,
       1.0 * SUM(PenaltisMarcados) / NULLIF(SUM(Partidos), 0) AS PenaltisPorPartido
FROM analisis.vw_Arbitro;
GO

-- 3 conjuntos: el perfil, la media de la liga y los partidos dirigidos.
CREATE OR ALTER PROCEDURE analisis.usp_PerfilArbitro
    @ArbitroID INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM liga.Arbitro WHERE ArbitroID = @ArbitroID)
        THROW 50805, N'Ese árbitro no existe.', 1;
    SELECT a.*, 100.0 * a.VictoriasLocales / NULLIF(a.Partidos, 0) AS PctLocal,
           1.0 * a.Goles / NULLIF(a.Partidos, 0) AS GolesPorPartido,
           1.0 * a.PenaltisMarcados / NULLIF(a.Partidos, 0) AS PenaltisPorPartido
    FROM analisis.vw_Arbitro AS a WHERE a.ArbitroID = @ArbitroID;
    SELECT * FROM analisis.vw_MediaLigaArbitros;
    SELECT j.Numero AS Jornada, p.FechaHora, l.EquipoID AS LocalID, l.Nombre AS Local, p.GolesLocal, p.GolesVisitante, v.EquipoID AS VisitanteID, v.Nombre AS Visitante
    FROM liga.Partido AS p
    JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
    JOIN liga.Equipo AS l ON l.EquipoID = p.EquipoLocalID
    JOIN liga.Equipo AS v ON v.EquipoID = p.EquipoVisitanteID
    WHERE p.ArbitroPrincipalID = @ArbitroID AND p.Estado = 'Finalizado'
    ORDER BY p.FechaHora, j.Numero;
END;
GO

IF DATABASE_PRINCIPAL_ID(N'rol_web_publico') IS NOT NULL
    GRANT EXECUTE ON OBJECT::analisis.usp_PerfilArbitro TO rol_web_publico;
GO
