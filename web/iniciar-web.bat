@echo off
rem LaLigaDB - arranca la web con doble clic.
rem La primera vez prepara Python (tarda un minuto); las siguientes arranca al momento.
chcp 65001 >nul
title LaLigaDB
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
    echo.
    echo   Preparando LaLigaDB por primera vez...
    python -m venv .venv || goto sin_python
    ".venv\Scripts\python.exe" -m pip install --quiet --disable-pip-version-check -r requirements.txt || goto error
)

rem Puente HTTPS de la IA (Caddy): se enciende solo si no lo está ya.
powershell -NoProfile -Command "exit [int](-not (Test-NetConnection 127.0.0.1 -Port 11443 -InformationLevel Quiet -WarningAction SilentlyContinue))" >nul 2>&1
if errorlevel 1 (
    where caddy >nul 2>&1 && start "Caddy - IA de LaLigaDB" /min caddy run --config "%~dp0..\ai\https\Caddyfile"
)

".venv\Scripts\python.exe" app.py --abrir
pause
exit /b

:sin_python
echo.
echo   No se encuentra Python. Instalalo desde https://www.python.org (marca "Add to PATH").
pause
exit /b 1

:error
echo.
echo   No se han podido instalar los componentes. Revisa la conexion a Internet.
pause
exit /b 1
