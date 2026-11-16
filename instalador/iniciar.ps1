<#
.SYNOPSIS
    Goalmetry - enciende lo necesario y abre la web (lo que hace el icono del escritorio).
.DESCRIPTION
    SQL Server arranca solo con Windows. Aqui se enciende Ollama (la IA) y Caddy (su puente HTTPS) si hacen
    falta y no estan ya encendidos, y despues se abre la web (web\iniciar-web.bat).
#>
$ErrorActionPreference = 'Continue'
$raiz = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'comun.ps1')
Actualizar-Path

$ollama = Buscar-Ollama
if ($ollama -and -not (Puerto-Abierto 11434)) {
    Write-Host 'Encendiendo la IA (Ollama)...'
    Start-Process -FilePath $ollama -ArgumentList 'serve' -WindowStyle Hidden
    [void](Esperar-Puerto 11434 30)
}

$caddy = Buscar-Caddy
if ($caddy -and $ollama -and -not (Puerto-Abierto 11443)) {
    Write-Host 'Encendiendo el puente HTTPS de la IA (Caddy)...'
    Start-Process -FilePath $caddy -ArgumentList 'run', '--config', (Join-Path $raiz 'ai\https\Caddyfile') -WindowStyle Hidden -WorkingDirectory $raiz
    [void](Esperar-Puerto 11443 20)
}

& (Join-Path $raiz 'web\iniciar-web.bat')
