@echo off
chcp 65001 >nul
title Clonador de voz - Inicio automatico
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0inicio-automatico.ps1"
echo.
pause
