/* =============================================================================
   06_security.sql
   Goalmetry (DP-800, Práctica 09) - Bloque C
   Seguridad con mínimo privilegio:
     1. Roles rol_admin, rol_analista y rol_ventas, con usuarios WITHOUT LOGIN (sin contraseñas).
     2. Permisos por esquema y por objeto: GRANT, DENY y REVOKE.
     3. Row-Level Security: cada usuario de ventas solo ve y modifica los abonados y las
        entradas de su equipo (filter + block predicates).
     4. Dynamic Data Masking en Email, Telefono y Documento; UNMASK por columna.
     5. Demo con EXECUTE AS USER / REVERT. Todo lo que modifica datos va en
        BEGIN TRAN ... ROLLBACK: el script no deja cambios en los datos.
   Ejecución:  sqlcmd -S localhost -E -C -b -i database\06_security.sql
   Idempotente: borra la política, las funciones, los usuarios y los roles antes de crearlos.
   ============================================================================= */
SET NOCOUNT ON;
USE LigaDB;
GO

/* ===================== 0. Limpieza ===================== */
DROP SECURITY POLICY IF EXISTS seguridad.pol_VentasPorEquipo;
DROP FUNCTION IF EXISTS seguridad.fn_FiltroEntrada;
DROP FUNCTION IF EXISTS seguridad.fn_FiltroEquipo;
DROP TABLE IF EXISTS seguridad.UsuarioEquipo;
DROP SCHEMA IF EXISTS seguridad;

-- Al borrar un usuario se borra también su pertenencia a roles; después ya se pueden borrar los roles.
DROP USER IF EXISTS u_admin;
DROP USER IF EXISTS u_analista;
DROP USER IF EXISTS u_ventas_barcelona;
DROP USER IF EXISTS u_ventas_madrid;
DROP USER IF EXISTS u_ventas_atletico;
DROP ROLE IF EXISTS rol_admin;
DROP ROLE IF EXISTS rol_analista;
DROP ROLE IF EXISTS rol_ventas;

-- SQL dinámico: un ALTER ... DROP MASKED escrito directamente se valida al compilar el lote
-- y falla (error 16007) si la columna no tiene máscara, aunque esté dentro de un IF.
DECLARE @quitarMascaras NVARCHAR(MAX) = N'';
SELECT @quitarMascaras += N'ALTER TABLE ventas.Abonado ALTER COLUMN ' + QUOTENAME(name) + N' DROP MASKED;'
FROM sys.masked_columns
WHERE object_id = OBJECT_ID(N'ventas.Abonado');
EXEC sys.sp_executesql @quitarMascaras;
GO

/* ===================== 1. Roles y usuarios ===================== */
CREATE ROLE rol_admin;
CREATE ROLE rol_analista;
CREATE ROLE rol_ventas;

-- WITHOUT LOGIN: usuarios de base de datos que no pueden conectarse por sí mismos;
-- solo se usan suplantándolos con EXECUTE AS USER. Así no hace falta ninguna contraseña.
CREATE USER u_admin            WITHOUT LOGIN;
CREATE USER u_analista         WITHOUT LOGIN;
CREATE USER u_ventas_barcelona WITHOUT LOGIN;
CREATE USER u_ventas_madrid    WITHOUT LOGIN;
CREATE USER u_ventas_atletico  WITHOUT LOGIN;

ALTER ROLE rol_admin    ADD MEMBER u_admin;
ALTER ROLE rol_analista ADD MEMBER u_analista;
ALTER ROLE rol_ventas   ADD MEMBER u_ventas_barcelona;
ALTER ROLE rol_ventas   ADD MEMBER u_ventas_madrid;
ALTER ROLE rol_ventas   ADD MEMBER u_ventas_atletico;
GO

/* ===================== 2. Permisos (los permisos se dan a roles, nunca a usuarios) ===================== */
-- rol_admin: control total de los esquemas del proyecto y ve los datos sin máscara.
GRANT CONTROL ON SCHEMA::liga   TO rol_admin;
GRANT CONTROL ON SCHEMA::ventas TO rol_admin;
GRANT CONTROL ON SCHEMA::ia     TO rol_admin;
GRANT UNMASK                    TO rol_admin;

-- rol_analista: lectura de datos deportivos; nada de datos personales ni de ventas.
GRANT SELECT  ON SCHEMA::liga                          TO rol_analista;
GRANT EXECUTE ON OBJECT::liga.usp_ClasificacionHastaJornada TO rol_analista;
DENY  SELECT  ON OBJECT::liga.PartidoAuditoria         TO rol_analista;  -- DENY de objeto gana al GRANT del esquema
DENY  SELECT  ON SCHEMA::ventas                        TO rol_analista;  -- DENY explícito: aunque alguien le dé
                                                                         -- un GRANT más adelante, seguirá sin acceso

-- rol_ventas: gestiona abonados y entradas (sin DELETE) y lee lo mínimo de liga para los joins.
GRANT SELECT, INSERT, UPDATE ON SCHEMA::ventas      TO rol_ventas;
GRANT SELECT ON OBJECT::liga.Equipo                 TO rol_ventas;
GRANT SELECT ON OBJECT::liga.Jornada                TO rol_ventas;
GRANT SELECT ON OBJECT::liga.Partido                TO rol_ventas;
GO

/* ===================== 3. Row-Level Security ===================== */
CREATE SCHEMA seguridad AUTHORIZATION dbo;   -- tabla de asignación y funciones de filtro; sin permisos para nadie
GO

-- Qué equipo gestiona cada usuario de ventas
CREATE TABLE seguridad.UsuarioEquipo
(
    NombreUsuario SYSNAME NOT NULL,
    EquipoID      INT     NOT NULL,
    CONSTRAINT PK_UsuarioEquipo        PRIMARY KEY (NombreUsuario),
    CONSTRAINT FK_UsuarioEquipo_Equipo FOREIGN KEY (EquipoID) REFERENCES liga.Equipo (EquipoID)
);

-- Se busca el equipo por nombre: no se depende de IDs escritos a mano
INSERT INTO seguridad.UsuarioEquipo (NombreUsuario, EquipoID)
SELECT v.NombreUsuario, e.EquipoID
FROM (VALUES (N'u_ventas_barcelona', N'Barcelona'),
             (N'u_ventas_madrid',    N'Real Madrid'),
             (N'u_ventas_atletico',  N'Atlético Madrid')) AS v (NombreUsuario, Equipo)
JOIN liga.Equipo AS e ON e.Nombre = v.Equipo;

IF @@ROWCOUNT <> 3
    THROW 50020, N'No se han encontrado los 3 equipos de los usuarios de ventas.', 1;
GO

-- Predicado por equipo. Inline TVF con SCHEMABINDING (obligatorio para RLS).
-- Pasan todas las filas para dbo (db_owner: así 03_insert_data.sql se puede volver a ejecutar)
-- y para rol_admin; los de ventas, solo las de su equipo; el resto, ninguna.
CREATE FUNCTION seguridad.fn_FiltroEquipo (@EquipoID INT)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS Permitido
    WHERE IS_MEMBER(N'db_owner') = 1
       OR IS_MEMBER(N'rol_admin') = 1
       OR EXISTS (SELECT 1
                  FROM seguridad.UsuarioEquipo AS ue
                  WHERE ue.NombreUsuario = USER_NAME()
                    AND ue.EquipoID      = @EquipoID);
GO

-- Entrada no tiene EquipoID: el equipo es el del abonado que la compra.
CREATE FUNCTION seguridad.fn_FiltroEntrada (@AbonadoID INT)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS Permitido
    WHERE IS_MEMBER(N'db_owner') = 1
       OR IS_MEMBER(N'rol_admin') = 1
       OR EXISTS (SELECT 1
                  FROM ventas.Abonado AS a
                  JOIN seguridad.UsuarioEquipo AS ue ON ue.EquipoID = a.EquipoID
                  WHERE a.AbonadoID      = @AbonadoID
                    AND ue.NombreUsuario = USER_NAME());
GO

-- FILTER: qué filas se ven (SELECT, UPDATE, DELETE).
-- BLOCK AFTER INSERT/UPDATE: impide dejar una fila que el propio usuario no podría ver
-- (p. ej. que ventas del Barcelona dé de alta un abonado del Madrid).
CREATE SECURITY POLICY seguridad.pol_VentasPorEquipo
    ADD FILTER PREDICATE seguridad.fn_FiltroEquipo(EquipoID)   ON ventas.Abonado,
    ADD BLOCK  PREDICATE seguridad.fn_FiltroEquipo(EquipoID)   ON ventas.Abonado AFTER INSERT,
    ADD BLOCK  PREDICATE seguridad.fn_FiltroEquipo(EquipoID)   ON ventas.Abonado AFTER UPDATE,
    ADD FILTER PREDICATE seguridad.fn_FiltroEntrada(AbonadoID) ON ventas.Entrada,
    ADD BLOCK  PREDICATE seguridad.fn_FiltroEntrada(AbonadoID) ON ventas.Entrada AFTER INSERT,
    ADD BLOCK  PREDICATE seguridad.fn_FiltroEntrada(AbonadoID) ON ventas.Entrada AFTER UPDATE
    WITH (STATE = ON);
GO

/* ===================== 4. Dynamic Data Masking ===================== */
ALTER TABLE ventas.Abonado ALTER COLUMN Email     ADD MASKED WITH (FUNCTION = 'email()');                  -- aXXX@XXXX.com
ALTER TABLE ventas.Abonado ALTER COLUMN Telefono  ADD MASKED WITH (FUNCTION = 'partial(0, "XXXXXX", 3)');  -- XXXXXX877
ALTER TABLE ventas.Abonado ALTER COLUMN Documento ADD MASKED WITH (FUNCTION = 'partial(0, "XXXXXX", 3)');  -- XXXXXX71P

-- UNMASK por columna (SQL Server 2022+): ventas necesita el email para contactar con el
-- abonado, pero no el teléfono ni el DNI.
GRANT UNMASK ON ventas.Abonado (Email) TO rol_ventas;
GO

/* ================================= Demo ================================= */
PRINT N'=== 1. Permisos efectivos por rol ===';
SELECT pr.name                                  AS Rol,
       pe.state_desc                            AS Estado,
       pe.permission_name                       AS Permiso,
       pe.class_desc                            AS Ambito,
       CASE pe.class
            WHEN 3 THEN SCHEMA_NAME(pe.major_id)
            WHEN 1 THEN OBJECT_SCHEMA_NAME(pe.major_id) + N'.' + OBJECT_NAME(pe.major_id)
                        + ISNULL(N' (' + COL_NAME(pe.major_id, NULLIF(pe.minor_id, 0)) + N')', N'')
            ELSE N'(base de datos)'
       END                                      AS Objeto
FROM sys.database_permissions AS pe
JOIN sys.database_principals  AS pr ON pr.principal_id = pe.grantee_principal_id
WHERE pr.name LIKE N'rol[_]%'
ORDER BY Rol, Estado DESC, Objeto, Permiso;
GO

PRINT N'=== 2. RLS: filas de ventas que ve cada usuario ===';
DROP TABLE IF EXISTS #Vista;
-- COLLATE DATABASE_DEFAULT: las tablas temporales usan la collation de tempdb, no la de LigaDB,
-- y sin esto el JOIN con seguridad.UsuarioEquipo da el error 468 (conflicto de intercalación).
CREATE TABLE #Vista (Usuario SYSNAME COLLATE DATABASE_DEFAULT, Abonados INT NULL, Entradas INT NULL,
                     Resultado NVARCHAR(200));

DECLARE @Usuario SYSNAME, @sql NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT u FROM (VALUES (N'dbo'), (N'u_admin'), (N'u_ventas_barcelona'), (N'u_ventas_madrid'),
                          (N'u_ventas_atletico'), (N'u_analista')) AS x (u);
OPEN c;
FETCH NEXT FROM c INTO @Usuario;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        IF @Usuario <> N'dbo' EXECUTE AS USER = @Usuario;
        INSERT INTO #Vista (Usuario, Abonados, Entradas, Resultado)
        SELECT USER_NAME(),
               (SELECT COUNT(*) FROM ventas.Abonado),
               (SELECT COUNT(*) FROM ventas.Entrada),
               N'OK';
        IF @Usuario <> N'dbo' REVERT;
    END TRY
    BEGIN CATCH
        IF @Usuario <> N'dbo' REVERT;
        INSERT INTO #Vista (Usuario, Resultado)
        VALUES (@Usuario, CONCAT(N'Error ', ERROR_NUMBER(), N': ', ERROR_MESSAGE()));
    END CATCH;
    FETCH NEXT FROM c INTO @Usuario;
END;
CLOSE c; DEALLOCATE c;

SELECT * FROM #Vista;

-- Comprobación: lo que ve cada vendedor = lo que dbo cuenta para su equipo
SELECT v.Usuario, v.Abonados, v.Entradas,
       (SELECT COUNT(*) FROM ventas.Abonado AS a WHERE a.EquipoID = ue.EquipoID)       AS AbonadosEquipo,
       (SELECT COUNT(*) FROM ventas.Entrada AS en
        JOIN ventas.Abonado AS a ON a.AbonadoID = en.AbonadoID
        WHERE a.EquipoID = ue.EquipoID)                                                  AS EntradasEquipo,
       CASE WHEN v.Abonados = (SELECT COUNT(*) FROM ventas.Abonado AS a WHERE a.EquipoID = ue.EquipoID)
                 AND v.Entradas = (SELECT COUNT(*) FROM ventas.Entrada AS en
                                   JOIN ventas.Abonado AS a ON a.AbonadoID = en.AbonadoID
                                   WHERE a.EquipoID = ue.EquipoID)
            THEN N'Correcto' ELSE N'ERROR' END                                           AS Comprobacion
FROM #Vista AS v
JOIN seguridad.UsuarioEquipo AS ue ON ue.NombreUsuario = v.Usuario;
DROP TABLE #Vista;
GO

PRINT N'=== 3. Enmascaramiento: el mismo abonado visto por cada usuario ===';
DECLARE @Abonado INT = (SELECT MIN(a.AbonadoID) FROM ventas.Abonado AS a
                        JOIN liga.Equipo AS e ON e.EquipoID = a.EquipoID
                        WHERE e.Nombre = N'Barcelona' AND a.Telefono IS NOT NULL);

SELECT N'dbo' AS VistoPor, Nombre, Email, Telefono, Documento FROM ventas.Abonado WHERE AbonadoID = @Abonado;

EXECUTE AS USER = N'u_admin';               -- UNMASK completo
SELECT USER_NAME() AS VistoPor, Nombre, Email, Telefono, Documento FROM ventas.Abonado WHERE AbonadoID = @Abonado;
REVERT;

EXECUTE AS USER = N'u_ventas_barcelona';    -- UNMASK solo en Email
SELECT USER_NAME() AS VistoPor, Nombre, Email, Telefono, Documento FROM ventas.Abonado WHERE AbonadoID = @Abonado;
REVERT;

EXECUTE AS USER = N'u_ventas_madrid';       -- RLS: el abonado no es de su equipo, ni siquiera lo ve
SELECT USER_NAME() AS VistoPor, COUNT(*) AS FilasVisibles FROM ventas.Abonado WHERE AbonadoID = @Abonado;
REVERT;

PRINT N'--- Límite de DDM: la máscara oculta el valor, pero no impide filtrar por él ---';
EXECUTE AS USER = N'u_ventas_barcelona';
SELECT USER_NAME() AS Usuario,
       COUNT(*)    AS AbonadosConDNIQueEmpiezaPor1    -- deduce información de una columna enmascarada
FROM ventas.Abonado
WHERE Documento LIKE '1%';
REVERT;
GO

PRINT N'=== 4. Operaciones que deben fallar (y una que debe funcionar) ===';
-- Variable de tabla y no #temporal: el ROLLBACK final deshace las filas de una tabla
-- temporal, pero no las de una variable de tabla, así que los resultados se conservan.
DECLARE @Pruebas TABLE (Prueba NVARCHAR(100), Usuario SYSNAME, Esperado NVARCHAR(30), Obtenido NVARCHAR(400));

DECLARE @Madrid INT = (SELECT EquipoID FROM liga.Equipo WHERE Nombre = N'Real Madrid');
DECLARE @Barca  INT = (SELECT EquipoID FROM liga.Equipo WHERE Nombre = N'Barcelona');
DECLARE @AbonadoBarca INT = (SELECT MIN(AbonadoID) FROM ventas.Abonado WHERE EquipoID = @Barca);

SET XACT_ABORT OFF;      -- los errores de permisos y de RLS abortan la sentencia, no la transacción
BEGIN TRANSACTION;

    EXECUTE AS USER = N'u_analista';
    BEGIN TRY SELECT TOP (1) @Madrid = @Madrid FROM ventas.Abonado;
              INSERT @Pruebas VALUES (N'Leer ventas.Abonado', USER_NAME(), N'Error 229', N'Sin error'); END TRY
    BEGIN CATCH INSERT @Pruebas VALUES (N'Leer ventas.Abonado', USER_NAME(), N'Error 229', CONCAT(N'Error ', ERROR_NUMBER())); END CATCH;

    BEGIN TRY SELECT TOP (1) @Madrid = @Madrid FROM liga.PartidoAuditoria;
              INSERT @Pruebas VALUES (N'Leer liga.PartidoAuditoria (DENY gana a GRANT)', USER_NAME(), N'Error 229', N'Sin error'); END TRY
    BEGIN CATCH INSERT @Pruebas VALUES (N'Leer liga.PartidoAuditoria (DENY gana a GRANT)', USER_NAME(), N'Error 229', CONCAT(N'Error ', ERROR_NUMBER())); END CATCH;

    BEGIN TRY EXEC liga.usp_RegistrarResultado @PartidoID = 94, @GolesLocal = 1, @GolesVisitante = 0;
              INSERT @Pruebas VALUES (N'Ejecutar usp_RegistrarResultado', USER_NAME(), N'Error 229', N'Sin error'); END TRY
    BEGIN CATCH INSERT @Pruebas VALUES (N'Ejecutar usp_RegistrarResultado', USER_NAME(), N'Error 229', CONCAT(N'Error ', ERROR_NUMBER())); END CATCH;
    REVERT;

    EXECUTE AS USER = N'u_ventas_barcelona';
    BEGIN TRY DELETE FROM ventas.Entrada WHERE AbonadoID = @AbonadoBarca;
              INSERT @Pruebas VALUES (N'Borrar entradas (sin permiso DELETE)', USER_NAME(), N'Error 229', N'Sin error'); END TRY
    BEGIN CATCH INSERT @Pruebas VALUES (N'Borrar entradas (sin permiso DELETE)', USER_NAME(), N'Error 229', CONCAT(N'Error ', ERROR_NUMBER())); END CATCH;

    BEGIN TRY INSERT INTO ventas.Abonado (EquipoID, Nombre, Email, Telefono, Documento)
              VALUES (@Madrid, N'Prueba Madrid', N'prueba.madrid@correo.example', NULL, '00000000T');
              INSERT @Pruebas VALUES (N'Alta de abonado de otro equipo', USER_NAME(), N'Error 33504', N'Sin error'); END TRY
    BEGIN CATCH INSERT @Pruebas VALUES (N'Alta de abonado de otro equipo', USER_NAME(), N'Error 33504', CONCAT(N'Error ', ERROR_NUMBER())); END CATCH;

    BEGIN TRY UPDATE ventas.Abonado SET EquipoID = @Madrid WHERE AbonadoID = @AbonadoBarca;
              INSERT @Pruebas VALUES (N'Pasar un abonado propio a otro equipo', USER_NAME(), N'Error 33504', N'Sin error'); END TRY
    BEGIN CATCH INSERT @Pruebas VALUES (N'Pasar un abonado propio a otro equipo', USER_NAME(), N'Error 33504', CONCAT(N'Error ', ERROR_NUMBER())); END CATCH;

    BEGIN TRY INSERT INTO ventas.Abonado (EquipoID, Nombre, Email, Telefono, Documento)
              VALUES (@Barca, N'Prueba Barcelona', N'prueba.barcelona@correo.example', NULL, '00000001R');
              INSERT @Pruebas VALUES (N'Alta de abonado de su equipo', USER_NAME(), N'Sin error', N'Sin error'); END TRY
    BEGIN CATCH INSERT @Pruebas VALUES (N'Alta de abonado de su equipo', USER_NAME(), N'Sin error', CONCAT(N'Error ', ERROR_NUMBER())); END CATCH;
    REVERT;

ROLLBACK TRANSACTION;    -- el alta de prueba no se queda en la BD

SELECT Prueba, Usuario, Esperado, Obtenido,
       CASE WHEN Obtenido = Esperado THEN N'Correcto' ELSE N'ERROR' END AS Comprobacion
FROM @Pruebas;
GO

PRINT N'=== 5. GRANT y REVOKE: rol_ventas y liga.Estadio ===';
DROP TABLE IF EXISTS #Revoke;
CREATE TABLE #Revoke (Paso NVARCHAR(60), Resultado NVARCHAR(200));

EXECUTE AS USER = N'u_ventas_barcelona';
BEGIN TRY INSERT #Revoke SELECT N'1. Antes del GRANT', CONCAT(COUNT(*), N' estadios') FROM liga.Estadio; END TRY
BEGIN CATCH INSERT #Revoke VALUES (N'1. Antes del GRANT', CONCAT(N'Error ', ERROR_NUMBER())); END CATCH;
REVERT;

GRANT SELECT ON OBJECT::liga.Estadio TO rol_ventas;
EXECUTE AS USER = N'u_ventas_barcelona';
BEGIN TRY INSERT #Revoke SELECT N'2. Tras GRANT SELECT', CONCAT(COUNT(*), N' estadios') FROM liga.Estadio; END TRY
BEGIN CATCH INSERT #Revoke VALUES (N'2. Tras GRANT SELECT', CONCAT(N'Error ', ERROR_NUMBER())); END CATCH;
REVERT;

REVOKE SELECT ON OBJECT::liga.Estadio FROM rol_ventas;   -- quita el GRANT (no es un DENY)
EXECUTE AS USER = N'u_ventas_barcelona';
BEGIN TRY INSERT #Revoke SELECT N'3. Tras REVOKE', CONCAT(COUNT(*), N' estadios') FROM liga.Estadio; END TRY
BEGIN CATCH INSERT #Revoke VALUES (N'3. Tras REVOKE', CONCAT(N'Error ', ERROR_NUMBER())); END CATCH;
REVERT;

SELECT * FROM #Revoke;
DROP TABLE #Revoke;
GO

PRINT N'=== 6. Auditoría: el trigger registra quién cambia un resultado (se deshace) ===';
-- El primer partido programado (con J1-J10, el 94) o, si ya no queda ninguno, el último.
-- @PermitirCorreccion = 1 para que funcione también con un partido ya jugado; todo se
-- deshace con el ROLLBACK.
DECLARE @PartidoDemo INT = COALESCE((SELECT MIN(PartidoID) FROM liga.Partido WHERE Estado = 'Programado'),
                                    (SELECT MAX(PartidoID) FROM liga.Partido));
BEGIN TRANSACTION;
    EXECUTE AS USER = N'u_admin';
    EXEC liga.usp_RegistrarResultado @PartidoID = @PartidoDemo, @GolesLocal = 1, @GolesVisitante = 1, @Estado = 'En juego',
                                     @PermitirCorreccion = 1;
    REVERT;
    SELECT PartidoID, EstadoAnterior, EstadoNuevo, GolesLocalNuevo, GolesVisitanteNuevo, Usuario
    FROM liga.PartidoAuditoria;
ROLLBACK TRANSACTION;
GO

PRINT N'=== 7. Estado final ===';
SELECT p.name AS Politica, p.is_enabled AS Activa,
       COUNT(*) AS Predicados
FROM sys.security_policies AS p
JOIN sys.security_predicates AS sp ON sp.object_id = p.object_id
GROUP BY p.name, p.is_enabled;

SELECT OBJECT_SCHEMA_NAME(object_id) + N'.' + OBJECT_NAME(object_id) AS Tabla, name AS Columna,
       masking_function AS Mascara
FROM sys.masked_columns
ORDER BY Columna;

SELECT (SELECT COUNT(*) FROM ventas.Abonado)    AS Abonados,         -- 2000
       (SELECT COUNT(*) FROM ventas.Entrada)    AS Entradas,         -- 200824
       (SELECT COUNT(*) FROM liga.PartidoAuditoria) AS FilasAuditoria, -- 0
       (SELECT Estado FROM liga.Partido WHERE PartidoID = 94) AS EstadoPartido94;  -- el de los CSV (Programado con J1-J10)
GO
