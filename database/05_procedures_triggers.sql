/* =============================================================================
   05_procedures_triggers.sql
   Proyecto LigaDB (DP-800, Práctica 09) - Bloque A
   Procedimientos y trigger:
     - liga.trg_Partido_AuditoriaResultado : registra en liga.PartidoAuditoria todo cambio
                                             de Estado o marcador en liga.Partido.
     - liga.usp_RegistrarResultado         : registra/corrige un resultado con validación,
                                             transacción, TRY/CATCH y THROW.
     - liga.usp_ClasificacionHastaJornada  : clasificación tal como estaba tras la jornada N.
   Ejecución:  sqlcmd -S localhost -E -C -b -i database\05_procedures_triggers.sql
   Idempotente: CREATE OR ALTER. La demo usa marcadores FICTICIOS dentro de
   BEGIN TRAN ... ROLLBACK, así que no deja ningún resultado inventado en la BD.
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

/* ---------- liga.trg_Partido_AuditoriaResultado ----------
   AFTER UPDATE y basado en conjuntos (inserted/deleted), así funciona igual si un UPDATE
   cambia varias filas. IS DISTINCT FROM (SQL Server 2022+) compara bien los NULL:
   NULL -> 2 cuenta como cambio y un UPDATE que deja los mismos valores no se audita. */
CREATE OR ALTER TRIGGER liga.trg_Partido_AuditoriaResultado
ON liga.Partido
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT (UPDATE(Estado) OR UPDATE(GolesLocal) OR UPDATE(GolesVisitante))
        RETURN;

    INSERT INTO liga.PartidoAuditoria
        (PartidoID, EstadoAnterior, GolesLocalAnterior, GolesVisitanteAnterior,
                    EstadoNuevo,    GolesLocalNuevo,    GolesVisitanteNuevo)
    SELECT i.PartidoID, d.Estado, d.GolesLocal, d.GolesVisitante,
                        i.Estado, i.GolesLocal, i.GolesVisitante
    FROM inserted AS i
    JOIN deleted  AS d ON d.PartidoID = i.PartidoID
    WHERE i.Estado         IS DISTINCT FROM d.Estado
       OR i.GolesLocal     IS DISTINCT FROM d.GolesLocal
       OR i.GolesVisitante IS DISTINCT FROM d.GolesVisitante;
END;
GO

/* ---------- liga.usp_RegistrarResultado ----------
   Errores propios (50001-50004) con THROW, para que el llamador sepa qué ha fallado.
   La lectura del partido se hace con UPDLOCK, HOLDLOCK dentro de la transacción: dos
   sesiones no pueden validar a la vez el mismo partido y pisarse el resultado.
   Si el llamador ya tiene una transacción abierta, el COMMIT interno solo baja @@TRANCOUNT
   y el ROLLBACK del CATCH deshace también la del llamador (comportamiento estándar). */
CREATE OR ALTER PROCEDURE liga.usp_RegistrarResultado
    @PartidoID          INT,
    @GolesLocal         TINYINT,
    @GolesVisitante     TINYINT,
    @Estado             VARCHAR(12) = 'Finalizado',
    @PermitirCorreccion BIT         = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF @Estado IS NULL OR @Estado NOT IN ('En juego', 'Finalizado')
            THROW 50002, N'Estado no válido: solo se admite ''En juego'' o ''Finalizado''.', 1;

        IF @GolesLocal IS NULL OR @GolesVisitante IS NULL
            THROW 50004, N'El marcador debe indicar los goles de los dos equipos.', 1;

        BEGIN TRANSACTION;

        DECLARE @EstadoActual VARCHAR(12);

        SELECT @EstadoActual = Estado
        FROM liga.Partido WITH (UPDLOCK, HOLDLOCK)
        WHERE PartidoID = @PartidoID;

        IF @EstadoActual IS NULL
            THROW 50001, N'El partido indicado no existe.', 1;

        IF @EstadoActual = 'Finalizado' AND @PermitirCorreccion = 0
            THROW 50003, N'El partido ya está finalizado. Para corregirlo, usar @PermitirCorreccion = 1.', 1;

        UPDATE liga.Partido
        SET GolesLocal     = @GolesLocal,
            GolesVisitante = @GolesVisitante,
            Estado         = @Estado
        WHERE PartidoID = @PartidoID;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;   -- relanza el error original (número, mensaje y línea)
    END CATCH;
END;
GO

/* ---------- liga.usp_ClasificacionHastaJornada ----------
   Misma lógica que liga.vw_Clasificacion, pero solo con las jornadas 1..@HastaJornada.
   Sirve para ver cómo estaba la tabla en cualquier punto de la temporada. */
CREATE OR ALTER PROCEDURE liga.usp_ClasificacionHastaJornada
    @HastaJornada TINYINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @HastaJornada IS NULL
       OR NOT EXISTS (SELECT 1 FROM liga.Jornada WHERE Numero = @HastaJornada)
        THROW 50010, N'La jornada indicada no está cargada.', 1;

    WITH Resultados AS
    (
        SELECT r.EquipoID, r.GF, r.GC
        FROM liga.Partido AS p
        JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
        CROSS APPLY (VALUES (p.EquipoLocalID,     p.GolesLocal,     p.GolesVisitante),
                            (p.EquipoVisitanteID, p.GolesVisitante, p.GolesLocal)) AS r (EquipoID, GF, GC)
        WHERE p.Estado = 'Finalizado'
          AND j.Numero <= @HastaJornada
    ),
    Totales AS
    (
        SELECT EquipoID,
               COUNT(*)                                 AS PJ,
               SUM(CASE WHEN GF > GC THEN 1 ELSE 0 END) AS G,
               SUM(CASE WHEN GF = GC THEN 1 ELSE 0 END) AS E,
               SUM(CASE WHEN GF < GC THEN 1 ELSE 0 END) AS P,
               SUM(CAST(GF AS INT))                     AS GF,
               SUM(CAST(GC AS INT))                     AS GC
        FROM Resultados
        GROUP BY EquipoID
    )
    SELECT RANK() OVER (ORDER BY t.G * 3 + t.E DESC, t.GF - t.GC DESC, t.GF DESC) AS Posicion,
           e.Nombre      AS Equipo,
           t.PJ, t.G, t.E, t.P, t.GF, t.GC,
           t.GF - t.GC   AS DG,
           t.G * 3 + t.E AS Pts
    FROM Totales     AS t
    JOIN liga.Equipo AS e ON e.EquipoID = t.EquipoID
    ORDER BY Posicion, Equipo;
END;
GO

/* ================================= Demo ================================= */
PRINT N'=== 1. usp_ClasificacionHastaJornada @HastaJornada = 5 ===';
EXEC liga.usp_ClasificacionHastaJornada @HastaJornada = 5;

PRINT N'=== 2. Errores controlados (no modifican nada) ===';
DECLARE @Finalizado INT = (SELECT MIN(PartidoID) FROM liga.Partido WHERE Estado = 'Finalizado');

BEGIN TRY EXEC liga.usp_RegistrarResultado @PartidoID = 999999, @GolesLocal = 1, @GolesVisitante = 0; END TRY
BEGIN CATCH SELECT N'Partido inexistente' AS Prueba, ERROR_NUMBER() AS Error, ERROR_MESSAGE() AS Mensaje; END CATCH;

BEGIN TRY EXEC liga.usp_RegistrarResultado @PartidoID = @Finalizado, @GolesLocal = 0, @GolesVisitante = 0; END TRY
BEGIN CATCH SELECT N'Partido ya finalizado' AS Prueba, ERROR_NUMBER() AS Error, ERROR_MESSAGE() AS Mensaje; END CATCH;

BEGIN TRY EXEC liga.usp_RegistrarResultado @PartidoID = @Finalizado, @GolesLocal = 0, @GolesVisitante = 0, @Estado = 'Programado'; END TRY
BEGIN CATCH SELECT N'Estado no válido' AS Prueba, ERROR_NUMBER() AS Error, ERROR_MESSAGE() AS Mensaje; END CATCH;

BEGIN TRY EXEC liga.usp_ClasificacionHastaJornada @HastaJornada = 30; END TRY
BEGIN CATCH SELECT N'Jornada no cargada' AS Prueba, ERROR_NUMBER() AS Error, ERROR_MESSAGE() AS Mensaje; END CATCH;

SELECT COUNT(*) AS FilasAuditoriaTrasErrores FROM liga.PartidoAuditoria;   -- debe ser 0
GO

PRINT N'=== 3. Registrar un resultado FICTICIO en un partido programado de la J10 (se deshace) ===';
SET XACT_ABORT ON;
BEGIN TRANSACTION;

    DECLARE @Programado INT =
        (SELECT MIN(p.PartidoID)
         FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
         WHERE j.Numero = 10 AND p.Estado = 'Programado');

    SELECT p.PartidoID, el.Nombre AS Local, ev.Nombre AS Visitante, p.Estado, p.GolesLocal, p.GolesVisitante
    FROM liga.Partido AS p
    JOIN liga.Equipo  AS el ON el.EquipoID = p.EquipoLocalID
    JOIN liga.Equipo  AS ev ON ev.EquipoID = p.EquipoVisitanteID
    WHERE p.PartidoID = @Programado;

    -- Descanso: 1-0 en juego. Final: corrección a 2-1 finalizado.
    EXEC liga.usp_RegistrarResultado @PartidoID = @Programado, @GolesLocal = 1, @GolesVisitante = 0, @Estado = 'En juego';
    EXEC liga.usp_RegistrarResultado @PartidoID = @Programado, @GolesLocal = 2, @GolesVisitante = 1;

    -- UPDATE directo que no cambia nada: el trigger no debe auditarlo.
    UPDATE liga.Partido SET Estado = Estado WHERE PartidoID = @Programado;

    PRINT N'--- Auditoría generada por el trigger (2 filas esperadas) ---';
    SELECT AuditoriaID, PartidoID,
           EstadoAnterior, GolesLocalAnterior, GolesVisitanteAnterior,
           EstadoNuevo,    GolesLocalNuevo,    GolesVisitanteNuevo,
           Usuario
    FROM liga.PartidoAuditoria
    WHERE PartidoID = @Programado
    ORDER BY AuditoriaID;

    PRINT N'--- La vista de clasificación ya incluye el resultado ficticio ---';
    SELECT c.Posicion, c.Equipo, c.PJ, c.Pts
    FROM liga.vw_Clasificacion AS c
    JOIN liga.Partido AS p ON c.EquipoID IN (p.EquipoLocalID, p.EquipoVisitanteID)
    WHERE p.PartidoID = @Programado;

ROLLBACK TRANSACTION;
GO

PRINT N'=== 4. Tras el ROLLBACK: la BD queda como estaba ===';
SELECT
    (SELECT COUNT(*) FROM liga.Partido AS p JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
     WHERE j.Numero = 10 AND p.Estado = 'Programado')     AS ProgramadosJ10,   -- 7
    (SELECT COUNT(*) FROM liga.Partido WHERE Estado = 'Finalizado') AS Finalizados,  -- 93
    (SELECT COUNT(*) FROM liga.PartidoAuditoria)          AS FilasAuditoria;   -- 0
GO
