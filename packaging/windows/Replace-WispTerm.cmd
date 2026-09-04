@echo off
setlocal
cd /d "%~dp0"
title WispTerm
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0replace-install.ps1"
if errorlevel 1 (
    echo.
    pause
)
