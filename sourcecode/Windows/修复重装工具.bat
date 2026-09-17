@echo off
rem ============================================================
rem  Claude Code Repair Tool launcher (ASCII only)
rem  Logic lives in installer\repair.ps1
rem ============================================================
title Claude Code Repair Tool
cd /d "%~dp0"

where powershell >nul 2>nul
if errorlevel 1 (
    echo [ERROR] PowerShell not found.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "installer\repair.ps1"
echo.
echo Repair window closes in 10 seconds...
timeout /t 10 >nul
exit /b %ERRORLEVEL%
