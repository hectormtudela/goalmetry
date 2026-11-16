@echo off
rem Goalmetry - instalacion con doble clic.
rem Pide permiso de administrador una sola vez y lo deja todo listo.
title Instalar Goalmetry
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "instalador\instalar-todo.ps1" %*
echo.
echo   Pulsa una tecla para cerrar esta ventana.
pause >nul
