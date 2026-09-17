@echo off
rem ============================================================
rem  Claude Code one-click installer launcher (ASCII only)
rem  Real logic lives in installer\main.ps1 (PowerShell 5.1+)
rem ============================================================
title Claude Code Installer
cd /d "%~dp0"

where powershell >nul 2>nul
if errorlevel 1 (
    echo [ERROR] PowerShell not found. This installer requires Windows 10 or later.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "installer\main.ps1"
set EXITCODE=%ERRORLEVEL%

echo.
if "%EXITCODE%"=="0" (
    echo Install finished. This window closes in 15 seconds...
    timeout /t 15 >nul
) else (
    echo Installer stopped with code %EXITCODE%.
    echo Check logs\ folder for details, then re-run this file to resume.
    pause
)
exit /b %EXITCODE%
