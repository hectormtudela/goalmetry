/* =============================================================================
   07_indexes.sql
   Proyecto LigaDB (DP-800, Práctica 09) - Bloque D
   Optimización de una consulta significativa sobre ventas.Entrada (200.824 filas):
   ingresos por partido de una jornada, con lo vendido en la última semana.
     1. ANTES: sin índice de apoyo (scan del índice clúster).
     2. Índice propuesto en el plan: (PartidoID, FechaCompra) INCLUDE (Precio).
        Con el RLS del Bloque C activo NO se usa; se demuestra desactivando el RLS.
     3. Índice final: se añade AbonadoID al INCLUDE (lo necesita el predicado de RLS).
   Se mide con el RLS activo, como en uso real, como dbo y como un usuario de ventas.
   Métricas: lecturas lógicas (no dependen de la caché), CPU y duración (la mejor de
   5 ejecuciones, con caché caliente) y operador de acceso a Entrada en el plan.
   Ejecución:  sqlcmd -S localhost -E -C -b -i database\07_indexes.sql
   Idempotente: borra el índice al principio y lo vuelve a crear al final.
   Requiere VIEW SERVER STATE (lee sys.dm_exec_query_stats); dbo/sysadmin lo tiene.
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

DROP INDEX IF EXISTS IX_Entrada_Partido ON ventas.Entrada;
GO

/* ---------- Consulta que se optimiza (para una jornada) ----------
   SELECT p.PartidoID, COUNT(*) AS Entradas, SUM(en.Precio) AS Ingresos,
          SUM(CASE WHEN en.FechaCompra >= DATEADD(DAY, -7, p.FechaHora)
                   THEN en.Precio ELSE 0 END) AS IngresosUltimaSemana
   FROM liga.Partido  AS p
   JOIN liga.Jornada  AS j  ON j.JornadaID  = p.JornadaID
   JOIN ventas.Entrada AS en ON en.PartidoID = p.PartidoID
   WHERE j.Numero = @Jornada
   GROUP BY p.PartidoID;
   ------------------------------------------------------------------ */

DROP TABLE IF EXISTS #Resultados;
CREATE TABLE #Resultados
(
    Orden           INT,
    Caso            NVARCHAR(80)  COLLATE DATABASE_DEFAULT,
    Usuario         SYSNAME       COLLATE DATABASE_DEFAULT,
    RLS             VARCHAR(3),
    Filas           BIGINT,
    LecturasLogicas BIGINT,
    CPUms           DECIMAL(10,2),
    DuracionMs      DECIMAL(10,2),
    AccesoEntrada   NVARCHAR(400) COLLATE DATABASE_DEFAULT
);
GO

/* Procedimiento temporal de medición: ejecuta la consulta @Ejecuciones veces (con una
   marca única en el texto para encontrarla en la caché de planes) y guarda en #Resultados
   las estadísticas de sys.dm_exec_query_stats y el operador de acceso a ventas.Entrada. */
CREATE PROCEDURE #Medir
    @Orden       INT,
    @Caso        NVARCHAR(80),
    @Usuario     SYSNAME = NULL,
    @Jornada     TINYINT = 5,
    @Ejecuciones INT     = 5
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @marca NVARCHAR(60) = CONCAT(N'/*D-', @Orden, N'-', NEWID(), N'*/');
    DECLARE @sql NVARCHAR(MAX) = N'
SELECT p.PartidoID, COUNT(*) AS Entradas, SUM(en.Precio) AS Ingresos,
       SUM(CASE WHEN en.FechaCompra >= DATEADD(DAY, -7, p.FechaHora) THEN en.Precio ELSE 0 END) AS IngresosUltimaSemana
FROM liga.Partido AS p
JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
JOIN ventas.Entrada AS en ON en.PartidoID = p.PartidoID
WHERE j.Numero = @Jornada
GROUP BY p.PartidoID ' + @marca;

    DECLARE @r TABLE (PartidoID INT, Entradas INT, Ingresos DECIMAL(12,2), IngresosUltimaSemana DECIMAL(12,2));
    DECLARE @i INT = 0;

    IF @Usuario IS NOT NULL EXECUTE AS USER = @Usuario;
    WHILE @i < @Ejecuciones
    BEGIN
        DELETE FROM @r;
        INSERT INTO @r EXEC sys.sp_executesql @sql, N'@Jornada TINYINT', @Jornada = @Jornada;
        SET @i += 1;
    END;
    IF @Usuario IS NOT NULL REVERT;

    INSERT INTO #Resultados
    SELECT @Orden, @Caso, ISNULL(@Usuario, USER_NAME()),
           (SELECT CASE WHEN is_enabled = 1 THEN 'ON' ELSE 'OFF' END
            FROM sys.security_policies WHERE name = N'pol_VentasPorEquipo'),
           qs.last_rows,
           qs.last_logical_reads,
           qs.min_worker_time  / 1000.0,      -- microsegundos -> ms; la mejor de las ejecuciones
           qs.min_elapsed_time / 1000.0,
           (SELECT STRING_AGG(CONCAT(n.value(N'@PhysicalOp', N'nvarchar(40)'), N' ',
                                     n.value(N'declare namespace s="http://schemas.microsoft.com/sqlserver/2004/07/showplan";
                                               (s:IndexScan/s:Object/@Index)[1]', N'nvarchar(60)'),   -- ya viene entre corchetes
                                     CASE WHEN n.value(N'declare namespace s="http://schemas.microsoft.com/sqlserver/2004/07/showplan";
                                                         (s:IndexScan/@Lookup)[1]', N'bit') = 1
                                          THEN N' (Key Lookup)' ELSE N'' END), N' + ')
            FROM qp.query_plan.nodes(N'declare namespace s="http://schemas.microsoft.com/sqlserver/2004/07/showplan";
                                       //s:RelOp[s:IndexScan/s:Object/@Table="[Entrada]"]') AS x (n))
    FROM sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
    CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
    -- Collation binaria explícita: el procedimiento temporal se compila en tempdb y, sin
    -- ella, el LIKE entre su collation y la del texto de la caché da el error 4191.
    WHERE st.text COLLATE Latin1_General_BIN2 LIKE (N'%' + @marca + N'%') COLLATE Latin1_General_BIN2
      AND st.text COLLATE Latin1_General_BIN2 NOT LIKE N'%dm_exec_query_stats%' COLLATE Latin1_General_BIN2;
END;
GO

/* ===================== 1. ANTES: sin índice ===================== */
PRINT N'=== 1. ANTES (sin IX_Entrada_Partido, RLS activo) ===';
PRINT N'--- Resultado de la consulta para la jornada 5 y estadísticas de E/S y tiempo ---';
SET STATISTICS IO, TIME ON;
SELECT p.PartidoID, COUNT(*) AS Entradas, SUM(en.Precio) AS Ingresos,
       SUM(CASE WHEN en.FechaCompra >= DATEADD(DAY, -7, p.FechaHora) THEN en.Precio ELSE 0 END) AS IngresosUltimaSemana
FROM liga.Partido AS p
JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
JOIN ventas.Entrada AS en ON en.PartidoID = p.PartidoID
WHERE j.Numero = 5
GROUP BY p.PartidoID
ORDER BY p.PartidoID;
SET STATISTICS IO, TIME OFF;

EXEC #Medir @Orden = 1, @Caso = N'Sin índice';
EXEC #Medir @Orden = 2, @Caso = N'Sin índice', @Usuario = N'u_ventas_barcelona';
GO

/* ===================== 2. Índice propuesto en el plan ===================== */
PRINT N'=== 2. Índice del plan: (PartidoID, FechaCompra) INCLUDE (Precio) ===';
CREATE NONCLUSTERED INDEX IX_Entrada_Partido
    ON ventas.Entrada (PartidoID, FechaCompra)
    INCLUDE (Precio);

EXEC #Medir @Orden = 3, @Caso = N'Índice del plan (sin AbonadoID)';

-- ¿Por qué no lo usa? El predicado de RLS (seguridad.fn_FiltroEntrada) necesita AbonadoID
-- de cada fila, y el índice no lo tiene: habría que hacer un Key Lookup por fila (~20.000)
-- y el optimizador prefiere recorrer el índice clúster. Prueba: con el RLS desactivado
-- un momento, el mismo índice sí se usa.
-- Sin transacción a propósito: un ROLLBACK también desharía la fila guardada en #Resultados.
-- Si algo falla, el CATCH vuelve a activar el RLS (y al final del script se comprueba).
BEGIN TRY
    ALTER SECURITY POLICY seguridad.pol_VentasPorEquipo WITH (STATE = OFF);
    EXEC #Medir @Orden = 4, @Caso = N'Índice del plan, RLS desactivado (prueba)';
    ALTER SECURITY POLICY seguridad.pol_VentasPorEquipo WITH (STATE = ON);
END TRY
BEGIN CATCH
    ALTER SECURITY POLICY seguridad.pol_VentasPorEquipo WITH (STATE = ON);
    THROW;
END CATCH;
GO

/* ===================== 3. Índice final ===================== */
PRINT N'=== 3. Índice final: (PartidoID, FechaCompra) INCLUDE (Precio, AbonadoID) ===';
-- Clave: PartidoID (seek por partido) y FechaCompra (ordena por fecha dentro de cada partido:
-- sirve también para consultas por rango de fechas de compra).
-- INCLUDE: Precio (lo que se suma) y AbonadoID (lo necesita el predicado de RLS). Así el
-- índice "cubre" la consulta: no hay que volver a la tabla.
DROP INDEX IX_Entrada_Partido ON ventas.Entrada;
CREATE NONCLUSTERED INDEX IX_Entrada_Partido
    ON ventas.Entrada (PartidoID, FechaCompra)
    INCLUDE (Precio, AbonadoID);

PRINT N'--- Estadísticas de E/S y tiempo con el índice final ---';
SET STATISTICS IO, TIME ON;
SELECT p.PartidoID, COUNT(*) AS Entradas, SUM(en.Precio) AS Ingresos,
       SUM(CASE WHEN en.FechaCompra >= DATEADD(DAY, -7, p.FechaHora) THEN en.Precio ELSE 0 END) AS IngresosUltimaSemana
FROM liga.Partido AS p
JOIN liga.Jornada AS j ON j.JornadaID = p.JornadaID
JOIN ventas.Entrada AS en ON en.PartidoID = p.PartidoID
WHERE j.Numero = 5
GROUP BY p.PartidoID
ORDER BY p.PartidoID;
SET STATISTICS IO, TIME OFF;

EXEC #Medir @Orden = 5, @Caso = N'Índice final (con AbonadoID)';
EXEC #Medir @Orden = 6, @Caso = N'Índice final (con AbonadoID)', @Usuario = N'u_ventas_barcelona';
GO

/* ===================== 4. Comparación ===================== */
PRINT N'=== 4. Comparación (jornada 5; CPU y duración = mejor de 5 ejecuciones) ===';
SELECT Orden, Caso, Usuario, RLS, Filas, LecturasLogicas, CPUms, DuracionMs, AccesoEntrada
FROM #Resultados
ORDER BY Orden;

PRINT N'--- Mejora del índice final frente a no tener índice ---';
SELECT a.Usuario,
       a.LecturasLogicas                                                         AS LecturasAntes,
       d.LecturasLogicas                                                         AS LecturasDespues,
       CAST(100.0 * (a.LecturasLogicas - d.LecturasLogicas) / a.LecturasLogicas AS DECIMAL(5,1)) AS ReduccionLecturasPct,
       a.CPUms AS CPUmsAntes, d.CPUms AS CPUmsDespues
FROM #Resultados AS a
JOIN #Resultados AS d ON d.Usuario = a.Usuario AND d.Orden IN (5, 6)
WHERE a.Orden IN (1, 2);

PRINT N'--- Coste del índice: espacio que ocupa frente a la tabla ---';
SELECT i.name                                        AS Indice,
       i.type_desc                                   AS Tipo,
       SUM(ps.used_page_count)                       AS Paginas,
       CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS DECIMAL(8,2)) AS MB
FROM sys.indexes AS i
JOIN sys.dm_db_partition_stats AS ps ON ps.object_id = i.object_id AND ps.index_id = i.index_id
WHERE i.object_id = OBJECT_ID(N'ventas.Entrada')
GROUP BY i.name, i.type_desc
ORDER BY Paginas DESC;

-- El índice queda creado y el RLS activo
SELECT (SELECT COUNT(*) FROM sys.indexes WHERE name = N'IX_Entrada_Partido')      AS IndiceCreado,
       (SELECT is_enabled FROM sys.security_policies WHERE name = N'pol_VentasPorEquipo') AS RLSActivo;

DROP TABLE #Resultados;
DROP PROCEDURE #Medir;
GO
