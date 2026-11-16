# Goalmetry - funciones comunes del instalador y del arranque (se cargan con ". comun.ps1").

function Actualizar-Path {
    # Un programa recien instalado no esta en el PATH de esta ventana hasta que se vuelve a leer.
    $env:Path = (@([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) | Where-Object { $_ }) -join ';'
}

function Puerto-Abierto([int] $puerto) {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $r = $c.BeginConnect('127.0.0.1', $puerto, $null, $null)
        $ok = $r.AsyncWaitHandle.WaitOne(600) -and $c.Connected
        $c.Close()
        return [bool] $ok
    } catch { return $false }
}

function Esperar-Puerto([int] $puerto, [int] $segundos = 40) {
    for ($i = 0; $i -lt $segundos; $i++) {
        if (Puerto-Abierto $puerto) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Buscar-Programa([string] $nombre, [string[]] $rutas) {
    $c = Get-Command $nombre -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($r in $rutas) {
        $f = Get-ChildItem -Path $r -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    return $null
}

function Buscar-Ollama { Buscar-Programa 'ollama' @("$env:LOCALAPPDATA\Programs\Ollama\ollama.exe", "$env:ProgramFiles\Ollama\ollama.exe") }
function Buscar-Caddy  { Buscar-Programa 'caddy'  @("$env:LOCALAPPDATA\Microsoft\WinGet\Packages\CaddyServer.Caddy_*\caddy.exe", "$env:ProgramFiles\Caddy\caddy.exe") }

function Buscar-Python {
    # Un Python valido (3.10 o mas): el "python" de la Tienda de Windows que no es de verdad no cuenta.
    $candidatos = @()
    $py = Get-Command py -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($py) { $candidatos += , @($py.Source, '-3') }
    $p = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { $candidatos += , @($p.Source) }
    foreach ($ruta in @("$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe")) {
        $f = Get-ChildItem -Path $ruta -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($f) { $candidatos += , @($f.FullName) }
    }
    foreach ($c in $candidatos) {
        try {
            $extra = @($c | Select-Object -Skip 1)
            $v = & $c[0] @extra -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
            if ($LASTEXITCODE -eq 0 -and $v -match '^3\.(\d+)$' -and [int]$Matches[1] -ge 10) { return , $c }
        } catch { }
    }
    return $null
}

function Valor-Sql([string] $consulta) {
    $r = & sqlcmd -S localhost -E -C -h -1 -W -Q "SET NOCOUNT ON; $consulta" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return (($r | Where-Object { $_ -match '\S' } | Select-Object -Last 1) -as [string]).Trim()
}
