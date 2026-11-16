<#
.SYNOPSIS
    Goalmetry: crea la base de datos LigaDB desde cero y la deja cargada y lista para usar.

.DESCRIPTION
    Ejecuta con sqlcmd, en orden, todos los scripts database\0*.sql (01_create_database,
    02_create_tables, 03_insert_data, ...). Si aparecen scripts nuevos con número
    (06_security.sql, 07_indexes.sql), se incluyen solos.
    Se para en el primer error (sqlcmd -b).

    ATENCIÓN: 01_create_database.sql BORRA LigaDB si ya existe (solo LigaDB;
    no toca ninguna otra base de datos de la instancia).

    Usa autenticación de Windows (-E): no hace falta ni se guarda ninguna contraseña.

    Solo para la primera instalación. Para cargar jornadas nuevas de data\ (tras un
    git pull) sin borrar nada, usa actualizar.ps1.

.PARAMETER Servidor
    Instancia de SQL Server 2025. Por defecto, la instancia local por defecto (localhost).
    Para una instancia con nombre: -Servidor "localhost\NOMBRE".
    Tiene que ser una instancia LOCAL: BULK INSERT lee los CSV desde el disco del servidor.

.PARAMETER Consultas
    Al terminar, ejecuta también database\consultas_avanzadas.sql (solo lectura).

.PARAMETER IA
    Ejecuta también los scripts de ai\ (embeddings, búsqueda y RAG). Requiere Ollama y el
    proxy HTTPS (Caddy) configurados como se explica en el README.

.PARAMETER Tests
    Al terminar, ejecuta tests\tests.sql (72 pruebas), tests\tests_web.sql (24) y
    tests\tests_simulacion.sql (que deja hecha la primera simulación). Con -IA,
    comprueba también la búsqueda y el RAG.

.PARAMETER CarpetaDatos
    Carpeta con los CSV. Por defecto, data\ del repositorio.

.PARAMETER Forzar
    No pide confirmación antes de borrar y volver a crear LigaDB.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\instalar.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\instalar.ps1 -Consultas -Forzar
#>
[CmdletBinding()]
param(
    [string] $Servidor = 'localhost',
    [switch] $Consultas,
    [switch] $IA,
    [switch] $Tests,
    [switch] $Forzar,
    [string] $CarpetaDatos
)

$ErrorActionPreference = 'Stop'
$raiz     = $PSScriptRoot
$dataPath = if ($CarpetaDatos) { (Resolve-Path $CarpetaDatos).Path } else { Join-Path $raiz 'data' }

function Escribir-Paso([string] $texto) { Write-Host "`n==> $texto" -ForegroundColor Cyan }

# ---------- Comprobaciones previas ----------
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    throw "No se encuentra 'sqlcmd'. Instálalo (winget install sqlcmd) o añádelo al PATH."
}
if (-not (Test-Path (Join-Path $dataPath 'partidos.csv'))) {
    throw "No se encuentran los CSV en '$dataPath'. Ejecuta el script desde la raíz del repositorio clonado."
}

Escribir-Paso "Comprobando la conexión con '$Servidor'"
$version = & sqlcmd -S $Servidor -E -C -b -h -1 -W -Q "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS varchar(5)) + '|' + CAST(SERVERPROPERTY('Edition') AS varchar(60))" 2>&1
if ($LASTEXITCODE -ne 0) { throw "No se puede conectar con '$Servidor':`n$version" }
$mayor, $edicion = ($version | Where-Object { $_ -match '\S' } | Select-Object -Last 1).Trim() -split '\|'
Write-Host "    SQL Server versión $mayor ($edicion)"
if ([int]$mayor -lt 17) {
    throw "Se necesita SQL Server 2025 (versión 17) o posterior: el proyecto usa VECTOR, REGEXP_LIKE, JSON_ARRAYAGG y EDIT_DISTANCE."
}

# ---------- Lista de scripts ----------
# Todos los scripts numerados (01_... 10_... 15_...), en orden.
$scripts = @(Get-ChildItem (Join-Path $raiz 'database') -Filter '*.sql' | Where-Object { $_.Name -match '^\d\d_' } | Sort-Object Name)
if ($Consultas) {
    $scripts += Get-Item (Join-Path $raiz 'database\consultas_avanzadas.sql')
}
if ($IA) {
    foreach ($nombre in 'create_external_model.sql', 'generate_embeddings.sql', 'vector_search.sql', 'temas.sql', 'rag.sql', 'intenciones.sql', 'rag_demo.sql') {
        $ruta = Join-Path $raiz "ai\$nombre"
        if (Test-Path $ruta) { $scripts += Get-Item $ruta }
        else { Write-Warning "ai\$nombre todavía no existe; se omite." }
    }
}

# La copia pública del repositorio no lleva las pruebas: con -Tests se avisa y se sigue sin ellas.
if ($Tests -and -not (Test-Path (Join-Path $raiz 'tests'))) {
    Write-Host 'Esta copia no incluye las pruebas (carpeta tests): se omiten.' -ForegroundColor Yellow
    $Tests = $false
}
if ($Tests) {
    $scripts += Get-Item (Join-Path $raiz 'tests\tests.sql')
    $scripts += Get-Item (Join-Path $raiz 'tests\tests_web.sql')
    $scripts += Get-Item (Join-Path $raiz 'tests\tests_simulacion.sql')
    $scripts += Get-Item (Join-Path $raiz 'tests\tests_analisis.sql')
    if ($IA) { $scripts += Get-Item (Join-Path $raiz 'tests\tests_temas.sql') }
}

Escribir-Paso 'Scripts que se van a ejecutar, en este orden'
$scripts | ForEach-Object { Write-Host ('    ' + $_.FullName.Substring($raiz.Length + 1)) }

# ---------- Confirmación ----------
if (-not $Forzar) {
    $existe = & sqlcmd -S $Servidor -E -C -b -h -1 -W -Q "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'LigaDB') IS NULL THEN 0 ELSE 1 END"
    if (($existe | Where-Object { $_ -match '\S' } | Select-Object -Last 1).Trim() -eq '1') {
        $respuesta = Read-Host "`nLigaDB ya existe en '$Servidor' y se va a BORRAR y volver a crear. ¿Continuar? (s/N)"
        if ($respuesta -notmatch '^[sS]') { Write-Host 'Cancelado. No se ha modificado nada.'; exit 0 }
    }
}

# ---------- Ejecución ----------
$total = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($s in $scripts) {
    $relativo = $s.FullName.Substring($raiz.Length + 1)
    Escribir-Paso $relativo
    $t = [System.Diagnostics.Stopwatch]::StartNew()
    # DataPath la usan 03_insert_data.sql, generate_embeddings.sql y tests.sql; al resto no le afecta.
    & sqlcmd -S $Servidor -E -C -b -W -v DataPath="$dataPath" -i $s.FullName
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`nERROR en $relativo (código $LASTEXITCODE). Se detiene la instalación." -ForegroundColor Red
        exit $LASTEXITCODE
    }
    Write-Host ("    OK ({0:N1} s)" -f $t.Elapsed.TotalSeconds) -ForegroundColor Green
}

# ---------- Datos externos: opcionales. Sin Internet se sigue y la aplicación lo dice ----------
Escribir-Paso 'Datos de fuentes externas (calendario, estadísticas, cuotas)'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $raiz 'externo\importar_externo.ps1') -Servidor $Servidor | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host '    AVISO: no se han podido importar. La aplicación funciona sin ellos.' -ForegroundColor Yellow }

# ---------- Resumen ----------
Escribir-Paso 'Resumen de la base de datos LigaDB'
& sqlcmd -S $Servidor -E -C -b -W -d LigaDB -Q @"
SET NOCOUNT ON;
SELECT s.name + '.' + t.name AS Tabla, SUM(p.rows) AS Filas
FROM sys.tables t
JOIN sys.schemas s    ON s.schema_id = t.schema_id
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE s.name IN ('liga', 'ventas', 'ia')
GROUP BY s.name, t.name
ORDER BY s.name, t.name;
"@
Write-Host ("`nGoalmetry instalado (base de datos LigaDB) en '{0}' en {1:N1} s." -f $Servidor, $total.Elapsed.TotalSeconds) -ForegroundColor Green
Write-Host "Prueba, por ejemplo:  sqlcmd -S $Servidor -E -C -d LigaDB -Q `"SELECT * FROM liga.vw_Clasificacion ORDER BY Posicion`""
