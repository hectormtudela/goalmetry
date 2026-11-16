@echo off
rem Goalmetry - arranca todo con doble clic (es lo que hace el icono del escritorio).
title Goalmetry
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "instalador\iniciar.ps1"
