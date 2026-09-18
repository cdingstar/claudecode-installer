@echo off
rem ============================================================
rem  Claude Code uninstaller launcher (Chinese text: GBK encoding, do NOT save as UTF-8)
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

if not exist "installer\uninstall.ps1" (
    echo 【错误】找不到 installer\uninstall.ps1
    echo 最常见原因：直接在压缩包里双击运行了本文件。
    echo 请先把整个压缩包完整解压到文件夹，再重新双击本文件。
    echo 若已解压仍出现此提示：可能是杀毒软件删除了文件，请恢复后重试。
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "installer\uninstall.ps1"
set EXITCODE=%ERRORLEVEL%

echo.
echo Uninstaller finished. Press any key to close this window...
pause >nul
exit /b %EXITCODE%
