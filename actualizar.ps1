<#
.SYNOPSIS
    Pone al día una LigaDB ya instalada con los CSV de data\ (por ejemplo, tras un git pull).

.DESCRIPTION
    Goalmetry. No borra ni vuelve a crear la base de datos: carga solo lo nuevo o lo que
    ha cambiado en los CSV.
      1. database\actualizar_datos.sql: valida los CSV y, en una sola transacción,
         inserta las filas nuevas y actualiza las que han cambiado. Si en la base de
         datos hay filas que no están en los CSV, se para sin cambiar nada y las lista.
      2. ai\generate_embeddings.sql (si la IA está instalada): pone al día las fichas,
         resúmenes, crónicas y textos del reglamento, y calcula los embeddings SOLO de
         los documentos nuevos o modificados.
      3. simulacion.usp_ActualizarPredicciones: vuelve a simular la temporada con los datos
         nuevos (menos de un minuto). Con -SinPredicciones se omite.
    Las ventas (abonados y entradas) son ficticias y fijas: no se tocan.

    Flujo habitual:   git pull   y después   .\actualizar.ps1
    Para la primera instalación se usa instalar.ps1.

.PARAMETER Servidor
    Instancia de SQL Server 2025 (por defecto, localhost). Tiene que ser local:
    BULK INSERT lee los CSV desde el disco del servidor.

.PARAMETER Simular
    Enseña qué cambiaría (filas nuevas y cambiadas por tabla) sin guardar nada.

.PARAMETER Tests
    Al terminar, ejecuta tests\tests.sql (y tests\tests_web.sql si la web está instalada).

.PARAMETER SinPredicciones
    No recalcula las predicciones. Se podrá hacer luego desde la web.

.PARAMETER CarpetaDatos
    Carpeta con los CSV. Por defecto, data\ del repositorio.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\actualizar.ps1 -Simular

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\actualizar.ps1 -Tests
#>
[CmdletBinding()]
param(
    [string] $Servidor = 'localhost',
    [switch] $Simular,
    [switch] $Tests,
    [switch] $SinPredicciones,
    [string] $CarpetaDatos
)

$ErrorActionPreference = 'Stop'
$raiz     = $PSScriptRoot
$dataPath = if ($CarpetaDatos) { (Resolve-Path $CarpetaDatos).Path } else { Join-Path $raiz 'data' }

function Escribir-Paso([string] $texto) { Write-Host "`n==> $texto" -ForegroundColor Cyan }
function Valor-Sql([string] $consulta) {
    $salida = & sqlcmd -S $Servidor -E -C -b -h -1 -W -Q "SET NOCOUNT ON; $consulta" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "No se puede consultar '$Servidor':`n$salida" }
    ($salida | Where-Object { $_ -match '\S' } | Select-Object -Last 1).Trim()
}

if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    throw "No se encuentra 'sqlcmd'. Instálalo (winget install sqlcmd) o añádelo al PATH."
}
foreach ($csv in 'partidos.csv', 'goles.csv', 'cronicas.csv', 'documentos.csv') {
    if (-not (Test-Path (Join-Path $dataPath $csv))) { throw "Falta '$csv' en '$dataPath'." }
}

Escribir-Paso "Comprobando LigaDB en '$Servidor'"
if ((Valor-Sql "SELECT CASE WHEN DB_ID(N'LigaDB') IS NULL THEN 0 ELSE 1 END") -ne '1') {
    Write-Host "    LigaDB no está instalada. Para la primera instalación usa instalar.ps1." -ForegroundColor Yellow
    exit 1
}
$conIA = (Valor-Sql "SELECT COUNT(*) FROM LigaDB.sys.external_models WHERE name = N'bge_m3_ollama'") -eq '1'
$conWeb = (Valor-Sql "SELECT COUNT(*) FROM LigaDB.sys.schemas WHERE name = N'web'") -eq '1'
$conPredicciones = (Valor-Sql "SELECT COUNT(*) FROM LigaDB.sys.schemas WHERE name = N'simulacion'") -eq '1'
Write-Host ("    Datos: {0}" -f $dataPath)
Write-Host ("    IA instalada: {0}" -f $(if ($conIA) { 'sí' } else { 'no (solo se actualizan los datos)' }))

$total = [System.Diagnostics.Stopwatch]::StartNew()

# ---------- 0a. Calendario externo (si hay Internet; sin él se sigue con lo que hubiera) ----------
if (-not $Simular -and (Valor-Sql "SELECT COUNT(*) FROM LigaDB.sys.schemas WHERE name = N'externo'") -eq '1') {
    Escribir-Paso 'Consultando las fuentes externas'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $raiz 'externo\importar_externo.ps1') -Servidor $Servidor | Out-Null
}

# ---------- 0. Congelar predicciones ANTES de cargar los resultados nuevos ----------
if (-not $Simular -and (Valor-Sql "SELECT COUNT(*) FROM LigaDB.sys.procedures WHERE name = N'usp_CongelarPredicciones'") -eq '1') {
    Escribir-Paso 'Congelando las predicciones de la próxima jornada'
    & sqlcmd -S $Servidor -E -C -b -W -d LigaDB -Q "SET NOCOUNT ON; EXEC simulacion.usp_CongelarPredicciones;"
    if ($LASTEXITCODE -ne 0) { Write-Host "    AVISO: no se han podido congelar las predicciones." -ForegroundColor Yellow }
}

# ---------- 1. Datos de la liga ----------
Escribir-Paso $(if ($Simular) { 'Simulando la actualización de los datos (no se guarda nada)' } else { 'Actualizando los datos de la liga' })
& sqlcmd -S $Servidor -E -C -b -W -v DataPath="$dataPath" Simular=$(if ($Simular) { 1 } else { 0 }) `
         -i (Join-Path $raiz 'database\actualizar_datos.sql')
if ($LASTEXITCODE -ne 0) {
    Write-Host "`nNo se ha actualizado nada (código $LASTEXITCODE). Revisa el mensaje de arriba." -ForegroundColor Red
    exit $LASTEXITCODE
}
if ($Simular) {
    Write-Host "`nSimulación terminada. Para aplicarla:  .\actualizar.ps1" -ForegroundColor Green
    exit 0
}

# ---------- 2. Documentos y embeddings ----------
$pendientes = $false
if ($conIA) {
    Escribir-Paso 'Actualizando documentos y embeddings (solo los nuevos o modificados)'
    & sqlcmd -S $Servidor -E -C -b -W -v DataPath="$dataPath" -i (Join-Path $raiz 'ai\generate_embeddings.sql')
    if ($LASTEXITCODE -ne 0) {
        $pendientes = $true
        Write-Host "`n    AVISO: los datos están actualizados, pero quedan documentos sin embedding." -ForegroundColor Yellow
        Write-Host "    Enciende Ollama y Caddy (caddy run --config ai\https\Caddyfile) y vuelve a ejecutar .\actualizar.ps1" -ForegroundColor Yellow
    }
}

# ---------- 2c. Datos externos: se contrastan con los resultados recién cargados ----------
if ((Valor-Sql "SELECT COUNT(*) FROM LigaDB.sys.schemas WHERE name = N'externo'") -eq '1' -and (Test-Path (Join-Path $raiz 'data\_externo'))) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $raiz 'externo\importar_externo.ps1') -Servidor $Servidor -SinDescargar | Out-Null
}

# ---------- 2b. Objetos nuevos ----------
if ($conIA) {
    foreach ($nombre in 'temas.sql', 'rag.sql', 'intenciones.sql') {
        & sqlcmd -S $Servidor -E -C -b -W -i (Join-Path $raiz "ai\$nombre") | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "    AVISO: no se ha podido aplicar ai\$nombre." -ForegroundColor Yellow }
    }
}
# Si el repositorio trae scripts de análisis nuevos (10_ y siguientes), se aplican: son idempotentes.
Escribir-Paso 'Aplicando los scripts de análisis'
Get-ChildItem (Join-Path $raiz 'database') -Filter '*.sql' | Where-Object { $_.Name -match '^(09|[1-9]\d)_' } | Sort-Object Name | ForEach-Object {
    & sqlcmd -S $Servidor -E -C -b -W -i $_.FullName | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "    AVISO: ha fallado $($_.Name)." -ForegroundColor Yellow }
}
$conPredicciones = (Valor-Sql "SELECT COUNT(*) FROM LigaDB.sys.schemas WHERE name = N'simulacion'") -eq '1'

# ---------- 3. Predicciones ----------
if ($conPredicciones -and -not $SinPredicciones) {
    Escribir-Paso 'Simulando la temporada con los datos nuevos'
    & sqlcmd -S $Servidor -E -C -b -W -d LigaDB -Q "SET NOCOUNT ON; EXEC simulacion.usp_ActualizarPredicciones;"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    AVISO: no se han podido recalcular las predicciones. Se puede hacer desde la web." -ForegroundColor Yellow
    }
}

# ---------- 4. Pruebas ----------
# La copia pública del repositorio no lleva las pruebas: con -Tests se avisa y se sigue sin ellas.
if ($Tests -and -not (Test-Path (Join-Path $raiz 'tests'))) {
    Write-Host 'Esta copia no incluye las pruebas (carpeta tests): se omiten.' -ForegroundColor Yellow
    $Tests = $false
}
if ($Tests) {
    $lista = @('tests\tests.sql')
    if ($conWeb) { $lista += 'tests\tests_web.sql' }
    if ($conPredicciones) { $lista += 'tests\tests_simulacion.sql' }
    $lista += 'tests\tests_analisis.sql'
    if ($conIA) { $lista += 'tests\tests_temas.sql'; $lista += 'tests\tests_rag_tarjetas.sql' }
    foreach ($p in $lista) {
        Escribir-Paso $p
        & sqlcmd -S $Servidor -E -C -b -W -v DataPath="$dataPath" -i (Join-Path $raiz $p)
        if ($LASTEXITCODE -ne 0) { Write-Host "`nFallan pruebas en $p." -ForegroundColor Red; exit $LASTEXITCODE }
    }
    # Pruebas de las pantallas, si la web está instalada
    $python = Join-Path $raiz 'web\.venv\Scripts\python.exe'
    if (Test-Path $python) {
        foreach ($p in 'tests\tests_pantallas.py', 'tests\tests_asistente.py') {
            Escribir-Paso $p
            & $python (Join-Path $raiz $p) | Select-Object -Last 1
            if ($LASTEXITCODE -ne 0) { Write-Host "`nFallan pruebas en $p." -ForegroundColor Red; exit $LASTEXITCODE }
        }
    }
}

Write-Host ("`nGoalmetry al día en {0:N1} s." -f $total.Elapsed.TotalSeconds) -ForegroundColor $(if ($pendientes) { 'Yellow' } else { 'Green' })
if ($pendientes) { exit 2 }
