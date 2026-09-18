@echo off
rem ============================================================
rem  Claude Code one-click installer launcher (Chinese text: GBK encoding, do NOT save as UTF-8)
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

if not exist "installer\main.ps1" (
    echo 【错误】找不到 installer\main.ps1
    echo 最常见原因：直接在压缩包里双击运行了本文件。
    echo 请先把整个压缩包完整解压到文件夹，再重新双击本文件。
    echo 若已解压仍出现此提示：可能是杀毒软件删除了文件，请恢复后重试。
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
