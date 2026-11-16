<#
.SYNOPSIS
    Goalmetry - instalador de doble clic: deja el ordenador listo y abre la web.
.DESCRIPTION
    Instala lo que falte (SQL Server 2025 Developer, sqlcmd, ODBC, Python y, si quieres la IA, Ollama
    y Caddy), crea la base de datos LigaDB, prepara la web y crea un icono en el escritorio.
    Todo es gratuito y local, sin cuentas. Cada paso comprueba primero si ya esta hecho: se puede
    repetir sin riesgo. Pide permiso de administrador una sola vez.
.PARAMETER ConIA
    Instala tambien la IA local (Ollama, Caddy y dos modelos de ~3 GB). Sin ella todo funciona salvo
    las preguntas a la IA y el buscador por significado.
.PARAMETER SinIA
    No instala la IA.
.PARAMETER Auto
    No pregunta nada: instala la IA solo si el equipo tiene memoria de sobra.
.PARAMETER Simular
    No instala ni cambia nada: cuenta lo que haria y lo que ya esta hecho.
#>
param(
    [switch] $ConIA,
    [switch] $SinIA,
    [switch] $Auto,
    [switch] $Simular,
    [string] $UsuarioOriginal
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'comun.ps1')

$identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
$esAdmin = ([Security.Principal.WindowsPrincipal] $identidad).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$yo = $identidad.Name
$registro = Join-Path $env:TEMP 'goalmetry-instalacion.log'

# ---------- Permiso de administrador (una sola vez) ----------
if (-not $Simular -and -not $esAdmin) {
    Write-Host ''
    Write-Host '  Goalmetry necesita permiso de administrador para instalar SQL Server.' -ForegroundColor Cyan
    Write-Host '  Windows te va a preguntar: elige "Si". El instalador sigue en la ventana nueva.' -ForegroundColor Cyan
    $lista = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-UsuarioOriginal', "`"$yo`"")
    foreach ($p in 'ConIA', 'SinIA', 'Auto') { if ($PSBoundParameters.ContainsKey($p)) { $lista += "-$p" } }
    try {
        $proceso = Start-Process -FilePath powershell -Verb RunAs -ArgumentList $lista -Wait -PassThru
    } catch {
        Write-Host '  No se ha dado el permiso, asi que no se ha instalado nada.' -ForegroundColor Yellow
        exit 1
    }
    exit $proceso.ExitCode
}
if ($UsuarioOriginal -and $UsuarioOriginal -ne $yo) {
    Write-Host "  Has dado permiso con otra cuenta ($yo) distinta de la tuya ($UsuarioOriginal)." -ForegroundColor Red
    Write-Host '  SQL Server quedaria a nombre de la otra cuenta. Entra en Windows con una cuenta de administrador y repite.' -ForegroundColor Red
    Read-Host 'Pulsa Intro para cerrar'
    exit 1
}
if (-not $Simular) { try { Start-Transcript -Path $registro -Force | Out-Null } catch { } }

# ---------- Utilidades ----------
$script:n = 0
$script:total = 9
$script:reinicio = $false
$script:hecho = New-Object System.Collections.ArrayList

function Paso([string] $t) { $script:n++; Write-Host ("`n[{0}/{1}] {2}" -f $script:n, $script:total, $t) -ForegroundColor Cyan }
function Bien([string] $t)  { Write-Host "    OK  $t" -ForegroundColor Green }
function Nota([string] $t)  { Write-Host "        $t" }
function Aviso([string] $t) { Write-Host "    AVISO: $t" -ForegroundColor Yellow }

function Salir([int] $codigo) {
    if (-not $Simular) { try { Stop-Transcript | Out-Null } catch { } }
    if (-not $Simular -and $esAdmin) { Write-Host ''; Read-Host 'Pulsa Intro para cerrar esta ventana' | Out-Null }
    exit $codigo
}
function Parar([string] $t) {
    Write-Host "`n    ERROR: $t" -ForegroundColor Red
    if (-not $Simular) { Write-Host "    El detalle esta en: $registro" -ForegroundColor Red }
    Salir 1
}

function Instalar-Winget([string] $id, [string] $nombre) {
    if ($Simular) { Nota "[simulacion] winget install $id"; return }
    Nota "Descargando e instalando $nombre (puede tardar varios minutos)..."
    & winget install --id $id --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    $c = $LASTEXITCODE
    # 0 = bien, 3010 = bien pero pide reiniciar, los otros dos = ya estaba instalado
    if ($c -in 0, 3010, -1978335135, -1978335189) {
        if ($c -eq 3010) { $script:reinicio = $true }
        [void]$script:hecho.Add($nombre)
        Actualizar-Path
        return
    }
    Parar "winget no ha podido instalar $nombre (codigo $c)."
}

# ---------- Cabecera ----------
Write-Host ''
Write-Host '  ====================================================' -ForegroundColor Green
Write-Host '    Goalmetry - instalacion' -ForegroundColor Green
Write-Host '  ====================================================' -ForegroundColor Green
if ($Simular) { Write-Host '  SIMULACION: no se instala ni se cambia nada. Solo se cuenta lo que se haria.' -ForegroundColor Yellow }
Actualizar-Path

# ---------- 1. Comprobar el equipo ----------
Paso 'Comprobando el equipo'
$so = Get-CimInstance Win32_OperatingSystem
if (-not [Environment]::Is64BitOperatingSystem -or [int]$so.BuildNumber -lt 10240) { Parar 'Hace falta Windows 10 u 11 de 64 bits.' }
Bien "$($so.Caption)"
$ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
$libre = [math]::Round((Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))).Free / 1GB, 1)
Bien "Memoria: $ram GB. Disco libre en $($env:SystemDrive): $libre GB"
if ($libre -lt 15) { Parar "Hacen falta unos 15 GB libres en $($env:SystemDrive) y hay $libre GB." }
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Parar 'No se encuentra winget. Abre la Microsoft Store y actualiza "Instalador de aplicacion" (App Installer); despues repite.'
}
try {
    [void](Invoke-WebRequest -Uri 'https://download.microsoft.com' -Method Head -UseBasicParsing -TimeoutSec 20)
    Bien 'Conexion a Internet'
} catch {
    if (-not $Simular) { Parar 'No hay conexion a Internet: hace falta para descargar los programas.' }
    Aviso 'Sin conexion a Internet (en la instalacion real haria falta).'
}

# Decidir si se instala la IA
$conIA = $false
if ($ConIA) { $conIA = $true }
elseif ($SinIA) { $conIA = $false }
else {
    $porDefecto = ($ram -ge 14)
    if ($Auto -or $Simular) { $conIA = $porDefecto }
    else {
        Write-Host ''
        Write-Host '  La IA local permite preguntar en lenguaje natural y buscar por significado.' -ForegroundColor White
        Write-Host '  Descarga unos 3 GB y va mejor con 16 GB de memoria. Sin ella, el resto funciona igual.' -ForegroundColor White
        $texto = if ($porDefecto) { '(S/n)' } else { '(s/N: tu equipo tiene poca memoria)' }
        $r = Read-Host "  Instalar tambien la IA? $texto"
        $conIA = if ([string]::IsNullOrWhiteSpace($r)) { $porDefecto } else { $r -match '^[sSyY]' }
    }
}
Bien ("IA local: " + $(if ($conIA) { 'si' } else { 'no' }))

# ---------- 2. sqlcmd y el controlador ODBC ----------
Paso 'Herramientas de SQL Server (sqlcmd y ODBC)'
if (Get-Command sqlcmd -CommandType Application -ErrorAction SilentlyContinue) { Bien 'sqlcmd ya instalado' }
else { Instalar-Winget 'Microsoft.Sqlcmd' 'sqlcmd' }
$odbc = Get-ItemProperty 'HKLM:\SOFTWARE\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server' -ErrorAction SilentlyContinue
if ($odbc) { Bien 'Controlador ODBC 18 ya instalado' }
else { Instalar-Winget 'Microsoft.msodbcsql.18' 'controlador ODBC 18 para SQL Server' }

# ---------- 3. SQL Server 2025 ----------
Paso 'SQL Server 2025 (edicion Developer, gratuita)'
$servicio = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
if (-not $servicio) {
    Nota 'No hay SQL Server. Se instala la edicion Developer (gratuita, solo para desarrollo y pruebas).'
    Nota 'Descarga y instalacion: de 10 a 30 minutos. No cierres la ventana.'
    Instalar-Winget 'Microsoft.SQLServer.2025.Developer' 'SQL Server 2025 Developer'
    $servicio = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue
    if (-not $Simular -and -not $servicio) {
        if ($script:reinicio) { Parar 'SQL Server pide reiniciar el equipo para terminar. Reinicia y vuelve a hacer doble clic en "Instalar Goalmetry": continuara donde lo dejo.' }
        Parar 'SQL Server no ha quedado instalado (no aparece el servicio MSSQLSERVER).'
    }
}
if ($servicio) {
    if ($servicio.Status -ne 'Running' -and -not $Simular) {
        Nota 'Encendiendo SQL Server...'
        Start-Service MSSQLSERVER
    }
    if (-not $Simular) {
        $listo = $false
        for ($i = 0; $i -lt 60 -and -not $listo; $i++) { if ((Valor-Sql 'SELECT 1') -eq '1') { $listo = $true } else { Start-Sleep -Seconds 2 } }
        if (-not $listo) { Parar 'SQL Server no responde en localhost. Reinicia el equipo y repite.' }
    }
    if ((Valor-Sql 'SELECT 1') -eq '1') {
        $mayor = [int](Valor-Sql "SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS varchar(5))")
        if ($mayor -lt 17) { Parar "Hay un SQL Server de version $mayor y Goalmetry necesita la 2025 (version 17). Instala la 2025 como instancia nueva y usa instalar.ps1 -Servidor 'localhost\NOMBRE'." }
        Bien "SQL Server version $mayor en marcha"
        if ((Valor-Sql "SELECT CAST(FULLTEXTSERVICEPROPERTY('IsFullTextInstalled') AS int)") -ne '1') {
            Parar ('A este SQL Server le falta la "Busqueda de texto completo" (Full-Text), que Goalmetry necesita. ' +
                   'Abre el "Centro de instalacion de SQL Server" > Instalacion > "Nueva instalacion independiente o agregar caracteristicas a una existente", ' +
                   'marca "Busqueda de texto completo y de semantica" y repite este instalador.')
        }
        Bien 'Busqueda de texto completo (Full-Text) disponible'
        if ((Valor-Sql "SELECT IS_SRVROLEMEMBER('sysadmin')") -ne '1') {
            Parar "Tu usuario ($yo) no es administrador de SQL Server, y hace falta para crear la base de datos."
        }
        Bien 'Tu usuario es administrador de SQL Server'
    } elseif ($Simular) { Aviso 'SQL Server esta instalado pero no responde ahora mismo.' }
} else { Nota '[simulacion] despues se comprobaria la version, Full-Text y los permisos' }

# ---------- 4. Python y la web ----------
Paso 'Python y la web'
$python = Buscar-Python
if ($python) { Bien 'Python ya instalado' }
else {
    Instalar-Winget 'Python.Python.3.12' 'Python 3.12'
    $python = Buscar-Python
    if (-not $Simular -and -not $python) { Parar 'Python se ha instalado pero no se encuentra. Reinicia el equipo y repite.' }
}
$venvPython = Join-Path $raiz 'web\.venv\Scripts\python.exe'
if (Test-Path $venvPython) { Bien 'Entorno de la web ya preparado' }
elseif ($Simular) { Nota '[simulacion] se crearia el entorno de la web (web\.venv) y se instalarian Flask, pyodbc y waitress' }
else {
    Nota 'Preparando el entorno de la web (un minuto)...'
    $extra = @($python | Select-Object -Skip 1)
    & $python[0] @extra -m venv (Join-Path $raiz 'web\.venv')
    if ($LASTEXITCODE -ne 0) { Parar 'No se ha podido crear el entorno de Python.' }
    & $venvPython -m pip install --quiet --disable-pip-version-check -r (Join-Path $raiz 'web\requirements.txt')
    if ($LASTEXITCODE -ne 0) { Parar 'No se han podido instalar los componentes de la web (revisa la conexion a Internet).' }
    Bien 'Entorno de la web preparado'
}

# ---------- 5. IA: Ollama y los modelos ----------
Paso 'IA local: Ollama y los modelos'
if (-not $conIA) { Nota 'Omitido (sin IA).' }
else {
    $ollama = Buscar-Ollama
    if ($ollama) { Bien 'Ollama ya instalado' }
    else {
        Instalar-Winget 'Ollama.Ollama' 'Ollama'
        $ollama = Buscar-Ollama
        if (-not $Simular -and -not $ollama) { Parar 'Ollama se ha instalado pero no se encuentra. Reinicia el equipo y repite.' }
    }
    if ($ollama -and -not $Simular) {
        if (-not (Puerto-Abierto 11434)) {
            Nota 'Encendiendo Ollama...'
            Start-Process -FilePath $ollama -ArgumentList 'serve' -WindowStyle Hidden
            if (-not (Esperar-Puerto 11434 40)) { Parar 'Ollama no arranca.' }
        }
        $modelos = (& $ollama list) -join "`n"
        foreach ($m in 'bge-m3', 'qwen2.5:3b') {
            if ($modelos -match [regex]::Escape($m)) { Bien "Modelo $m ya descargado" }
            else {
                Nota "Descargando el modelo $m (unos GB: puede tardar)..."
                & $ollama pull $m
                if ($LASTEXITCODE -ne 0) { Parar "No se ha podido descargar el modelo $m." }
                Bien "Modelo $m descargado"
            }
        }
    } elseif ($Simular) { Nota '[simulacion] se encenderia Ollama y se descargarian bge-m3 y qwen2.5:3b si faltan' }
}

# ---------- 6. IA: Caddy (puente HTTPS) ----------
Paso 'IA local: Caddy (puente HTTPS entre SQL Server y la IA)'
if (-not $conIA) { Nota 'Omitido (sin IA).' }
else {
    $caddy = Buscar-Caddy
    if ($caddy) { Bien 'Caddy ya instalado' }
    else {
        Instalar-Winget 'CaddyServer.Caddy' 'Caddy'
        $caddy = Buscar-Caddy
        if (-not $Simular -and -not $caddy) { Parar 'Caddy se ha instalado pero no se encuentra. Reinicia el equipo y repite.' }
    }
    if ($caddy -and -not $Simular) {
        if (-not (Puerto-Abierto 11443)) {
            Nota 'Encendiendo Caddy...'
            Start-Process -FilePath $caddy -ArgumentList 'run', '--config', (Join-Path $raiz 'ai\https\Caddyfile') -WindowStyle Hidden -WorkingDirectory $raiz
            if (-not (Esperar-Puerto 11443 40)) { Parar 'Caddy no arranca.' }
        }
        Nota 'Registrando el certificado local de Caddy (si Windows pregunta si confias en el, di que si: es el de tu propio ordenador).'
        & $caddy trust 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Aviso 'No se ha podido registrar el certificado. Si la IA falla, ejecuta "caddy trust" como administrador.' }
        else { Bien 'Certificado local registrado' }
    } elseif ($Simular) { Nota '[simulacion] se encenderia Caddy y se registraria su certificado local con "caddy trust"' }
}

# ---------- 7. La base de datos ----------
Paso 'Base de datos LigaDB'
$existe = if ((Valor-Sql 'SELECT 1') -eq '1') { Valor-Sql "SELECT CASE WHEN DB_ID(N'LigaDB') IS NULL THEN 0 ELSE 1 END" } else { $null }
if ($existe -eq '1') { Bien 'LigaDB ya existe: no se toca. (Para cargar jornadas nuevas, usa actualizar.ps1.)' }
elseif ($Simular) { Nota '[simulacion] se crearia LigaDB con instalar.ps1' + $(if ($conIA) { ' -IA' } else { '' }) }
else {
    Nota 'Creando LigaDB y cargando los datos' + $(if ($conIA) { ' y la IA (unos minutos)...' } else { '...' })
    $opciones = @('-Forzar', '-SinDemo')
    if ($conIA) { $opciones += '-IA' }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $raiz 'instalar.ps1') @opciones
    if ($LASTEXITCODE -ne 0) { Parar 'No se ha podido crear la base de datos. Mira el error de arriba.' }
    Bien 'LigaDB creada'
}

# ---------- 8. Icono en el escritorio ----------
Paso 'Icono de Goalmetry en el escritorio'
$arranque = Join-Path $raiz 'Iniciar Goalmetry.bat'
if ($Simular) { Nota '[simulacion] se crearia el icono "Goalmetry" en el escritorio' }
else {
    $acceso = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Goalmetry.lnk'))
    $acceso.TargetPath = $arranque
    $acceso.WorkingDirectory = $raiz
    $acceso.Description = 'Abre Goalmetry'
    $acceso.Save()
    Bien 'Icono creado: de ahora en adelante, haz doble clic en "Goalmetry" del escritorio'
}

# ---------- 9. Terminar ----------
Paso 'Terminado'
Write-Host ''
if ($Simular) { Write-Host '  Fin de la simulacion: no se ha cambiado nada.' -ForegroundColor Yellow }
else {
    Write-Host '  Goalmetry esta instalado.' -ForegroundColor Green
    if ($script:hecho.Count) { Write-Host ('  Instalado ahora: ' + ($script:hecho -join ', ')) }
    Write-Host '  Si quieres entrar al panel de administracion, haz doble clic en web\crear-admin.bat (una vez).'
    Write-Host '  SQL Server Developer es gratuito pero solo para desarrollo y pruebas, no para produccion.'
    if ($script:reinicio) { Aviso 'Windows pide reiniciar para terminar alguna instalacion. Conviene reiniciar pronto.' }
    Write-Host '  Abriendo Goalmetry en el navegador...' -ForegroundColor Cyan
    Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $arranque)
}
Salir 0
