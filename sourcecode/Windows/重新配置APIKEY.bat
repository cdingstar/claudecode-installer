@echo off
rem ============================================================
rem  Claude Code API Key reconfiguration launcher
rem  Logic lives in installer\reconfig.ps1
rem ============================================================
title Claude Code API Key Config
cd /d "%~dp0"

where powershell >nul 2>nul
if errorlevel 1 (
    echo [ERROR] PowerShell not found.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "installer\reconfig.ps1"
echo.
echo Config window closes in 10 seconds...
timeout /t 10 >nul
exit /b %ERRORLEVEL%
