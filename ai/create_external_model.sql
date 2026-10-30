/* =============================================================================
   create_external_model.sql
   Goalmetry (DP-800, Práctica 09) - Bloque E (1/2)
   Conecta SQL Server 2025 con el modelo de embeddings local (bge-m3, en Ollama):
     SQL Server --HTTPS--> Caddy (https://localhost:11443) --HTTP--> Ollama (:11434)
   Pasos:
     1. Activa 'external rest endpoint enabled' (opción de la instancia).
     2. Llamada de prueba con sp_invoke_external_rest_endpoint: comprueba, antes de
        crear nada, que SQL Server confía en el certificado de Caddy y que la API
        responde con un vector de 1024 dimensiones.
     3. CREATE EXTERNAL MODEL y comprobación con AI_GENERATE_EMBEDDINGS.
   Requisitos: Ollama con 'bge-m3' y Caddy en marcha (ver ai/https/Caddyfile):
     caddy run --config ai\https\Caddyfile
   Ejecución:  sqlcmd -S localhost -E -C -b -i ai\create_external_model.sql
   Idempotente. Sin secretos: Ollama local no usa claves, por lo que no hay CREDENTIAL.
   ============================================================================= */
SET NOCOUNT ON;
GO

/* ---------- 1. Habilitar las llamadas REST desde T-SQL ---------- */
EXEC sp_configure 'external rest endpoint enabled', 1;
RECONFIGURE;
GO

USE LigaDB;
GO

/* ---------- 2. Llamada de prueba al endpoint ---------- */
PRINT N'--- Llamada de prueba a https://localhost:11443/api/embed ---';
DECLARE @codigo INT, @respuesta NVARCHAR(MAX);
EXEC @codigo = sp_invoke_external_rest_endpoint
     @url     = N'https://localhost:11443/api/embed',
     @method  = 'POST',
     @headers = N'{"Content-Type":"application/json"}',
     @payload = N'{"model":"bge-m3","input":"prueba de conexión"}',
     @timeout = 120,
     @response = @respuesta OUTPUT;

SELECT @codigo                                                    AS CodigoRetorno,
       CAST(JSON_VALUE(@respuesta, '$.response.status.http.code') AS INT) AS HttpStatus,
       (SELECT COUNT(*) FROM OPENJSON(@respuesta, '$.result.embeddings[0]')) AS Dimensiones;

IF @codigo <> 0 OR (SELECT COUNT(*) FROM OPENJSON(@respuesta, '$.result.embeddings[0]')) <> 1024
    THROW 50100, N'La llamada de prueba a Ollama/Caddy ha fallado o no devuelve 1024 dimensiones.', 1;
GO

/* ---------- 3. Modelo externo ---------- */
IF EXISTS (SELECT 1 FROM sys.external_models WHERE name = N'bge_m3_ollama')
    DROP EXTERNAL MODEL bge_m3_ollama;
GO

CREATE EXTERNAL MODEL bge_m3_ollama
WITH (
    LOCATION   = 'https://localhost:11443/api/embed',
    API_FORMAT = 'Ollama',
    MODEL_TYPE = EMBEDDINGS,
    MODEL      = 'bge-m3'
);
GO

-- Si está instalada la web (database\08_web.sql), su rol necesita usar el modelo.
-- Al volver a crear el modelo se pierde el permiso, por eso se da aquí otra vez.
IF DATABASE_PRINCIPAL_ID(N'rol_web_publico') IS NOT NULL
    GRANT EXECUTE ON EXTERNAL MODEL::bge_m3_ollama TO rol_web_publico;
GO

PRINT N'--- Modelo registrado ---';
SELECT CAST(name AS NVARCHAR(30)) AS Nombre, CAST(api_format AS NVARCHAR(10)) AS ApiFormat,
       CAST(model_type_desc AS NVARCHAR(12)) AS Tipo, CAST(model AS NVARCHAR(10)) AS Modelo,
       CAST(location AS NVARCHAR(50)) AS Ubicacion
FROM sys.external_models
WHERE name = N'bge_m3_ollama';

PRINT N'--- Comprobación: AI_GENERATE_EMBEDDINGS devuelve un VECTOR(1024) ---';
DECLARE @v VECTOR(1024) = AI_GENERATE_EMBEDDINGS(N'¿Quién es el máximo goleador de LaLiga?' USE MODEL bge_m3_ollama);
SELECT CAST(VECTORPROPERTY(@v, 'Dimensions') AS INT)          AS Dimensiones,
       CAST(VECTORPROPERTY(@v, 'BaseType') AS NVARCHAR(10)) AS TipoBase;
GO
