@echo off
rem ============================================================
rem  Claude Code uninstaller launcher (ASCII only)
rem  Real logic lives in installer\uninstall.ps1 (PowerShell 5.1+)
rem  Removes user-level copies installed by this installer only.
rem ============================================================
title Claude Code Uninstaller
cd /d "%~dp0"

where powershell >nul 2>nul
if errorlevel 1 (
    echo [ERROR] PowerShell not found. This tool requires Windows 10 or later.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "installer\uninstall.ps1"
set EXITCODE=%ERRORLEVEL%

echo.
echo Uninstaller finished. Press any key to close this window...
pause >nul
exit /b %EXITCODE%
