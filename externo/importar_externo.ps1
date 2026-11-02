<#
.SYNOPSIS
    Goalmetry - Importa datos de fuentes externas públicas a las tablas separadas del esquema externo.
.DESCRIPTION
    Fuentes, gratuitas y sin registro:
      - football-data.co.uk: SP1.csv (estadísticas y cuotas) y fixtures.csv (próximos partidos).
      - openfootball (GitHub): calendario 2026-27 y resultados de temporadas anteriores.
    Lo descargado se guarda en data\_externo (ignorada por git) y no se vuelve a pedir si tiene
    menos de 6 horas. Nunca escribe en liga.* ni en los CSV de data\.
    Si no hay Internet, avisa y sigue: la aplicación dice en pantalla que no hay datos externos.
.PARAMETER Servidor
    Instancia de SQL Server. Por defecto, localhost.
.PARAMETER SinDescargar
    Vuelve a cargar lo ya descargado, sin pedir nada a Internet.
#>
param(
    [string] $Servidor = 'localhost',
    [switch] $SinDescargar
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $raiz 'data\_externo'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

$fuentes = [ordered]@{
    'SP1.csv'          = 'https://www.football-data.co.uk/mmz4281/2627/SP1.csv'
    'fixtures.csv'     = 'https://www.football-data.co.uk/fixtures.csv'
    'es1_2026-27.json' = 'https://raw.githubusercontent.com/openfootball/football.json/master/2026-27/es.1.json'
    'es1_2025-26.json' = 'https://raw.githubusercontent.com/openfootball/football.json/master/2025-26/es.1.json'
    'es1_2024-25.json' = 'https://raw.githubusercontent.com/openfootball/football.json/master/2024-25/es.1.json'
}

# ---------- Descarga: puntual y pausada ----------
if (-not $SinDescargar) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($nombre in $fuentes.Keys) {
        $destino = Join-Path $dir $nombre
        if ((Test-Path $destino) -and ((Get-Item $destino).LastWriteTime -gt (Get-Date).AddHours(-6))) { continue }
        try {
            $temporal = "$destino.tmp"
            Invoke-WebRequest -Uri $fuentes[$nombre] -OutFile $temporal -UseBasicParsing -TimeoutSec 30
            Move-Item -Force $temporal $destino
            Write-Host "    Descargado $nombre"
        } catch {
            Write-Host "    AVISO: no se ha podido descargar $nombre. Se sigue sin él." -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 2
    }
}

function Numero([string] $v) { if ($v -match '^\d+(\.\d+)?$') { return [double]::Parse($v, [Globalization.CultureInfo]::InvariantCulture) } return $null }
function Fecha([string] $v) {
    # football-data escribe dd/MM/yyyy
    if ($v -match '^(\d{2})/(\d{2})/(\d{2,4})$') {
        $a = if ($Matches[3].Length -eq 2) { "20$($Matches[3])" } else { $Matches[3] }
        return "$a-$($Matches[2])-$($Matches[1])"
    }
    return $null
}
function Guardar($filas, [string] $nombre) {
    $json = if (@($filas).Count) { ConvertTo-Json -InputObject @($filas) -Compress -Depth 3 } else { '[]' }
    [IO.File]::WriteAllText((Join-Path $dir $nombre), $json, [Text.Encoding]::Unicode)
}

# ---------- Normalización ----------
$resultados = @()
$sp1 = Join-Path $dir 'SP1.csv'
if (Test-Path $sp1) {
    $resultados = @(Import-Csv $sp1 -Encoding UTF8 | Where-Object { $_.HomeTeam -and $_.FTHG -ne '' } | ForEach-Object {
        [pscustomobject]@{
            Fecha = Fecha $_.Date; Hora = $_.Time; Local = $_.HomeTeam; Visitante = $_.AwayTeam
            GL = Numero $_.FTHG; GV = Numero $_.FTAG; TL = Numero $_.HS; TV = Numero $_.AS; APL = Numero $_.HST; APV = Numero $_.AST
            CL = Numero $_.HC; CV = Numero $_.AC; AL = Numero $_.HY; AV = Numero $_.AY; RL = Numero $_.HR; RV = Numero $_.AR
            XgL = Numero $_.HxG; XgV = Numero $_.AxG; C1 = Numero $_.AvgH; CX = Numero $_.AvgD; C2 = Numero $_.AvgA
        }
    })
}
Guardar $resultados 'norm_resultados.json'

$proximos = @()
$fix = Join-Path $dir 'fixtures.csv'
if (Test-Path $fix) {
    $proximos = @(Import-Csv $fix -Encoding UTF8 | Where-Object { $_.Div -eq 'SP1' -and $_.HomeTeam } | ForEach-Object {
        [pscustomobject]@{ Fecha = Fecha $_.Date; Hora = $_.Time; Local = $_.HomeTeam; Visitante = $_.AwayTeam
                           C1 = Numero $_.AvgH; CX = Numero $_.AvgD; C2 = Numero $_.AvgA }
    })
}
Guardar $proximos 'norm_proximos.json'

function Leer-Temporada([string] $fichero, [string] $temporada) {
    $ruta = Join-Path $dir $fichero
    if (-not (Test-Path $ruta)) { return @() }
    try {
        $d = [IO.File]::ReadAllText($ruta, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        Write-Host "    AVISO: $fichero no se puede leer. Se sigue sin él." -ForegroundColor Yellow
        return @()
    }
    return @($d.matches | ForEach-Object {
        $ft = if ($_.score -and $_.score.ft) { $_.score.ft } else { $null }
        [pscustomobject]@{
            Temporada = $temporada
            Jornada = if ($_.round -match '(\d+)\s*$') { [int]$Matches[1] } else { $null }
            Fecha = $_.date; Hora = $_.time; Local = $_.team1; Visitante = $_.team2
            GL = if ($ft) { $ft[0] } else { $null }; GV = if ($ft) { $ft[1] } else { $null }
        }
    })
}
Guardar (Leer-Temporada 'es1_2026-27.json' '2026-27') 'norm_calendario.json'
Guardar (@(Leer-Temporada 'es1_2024-25.json' '2024-25') + @(Leer-Temporada 'es1_2025-26.json' '2025-26')) 'norm_historico.json'

# ---------- Carga y contraste en SQL ----------
& sqlcmd -S $Servidor -E -C -b -W -v RutaExterno="$dir" -i (Join-Path $PSScriptRoot 'cargar_externo.sql')
if ($LASTEXITCODE -ne 0) { Write-Host '    AVISO: no se han podido cargar los datos externos.' -ForegroundColor Yellow }
exit 0
