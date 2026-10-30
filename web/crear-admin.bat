@echo off
rem Goalmetry - crea o cambia la cuenta de administrador.
chcp 65001 >nul
title Goalmetry - cuenta de administrador
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
    echo   Abre primero la web una vez con iniciar-web.bat.
    pause
    exit /b 1
)
".venv\Scripts\python.exe" crear_admin.py
pause
