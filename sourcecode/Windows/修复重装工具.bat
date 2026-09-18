@echo off
rem ============================================================
rem  Claude Code Repair Tool launcher (Chinese text: GBK encoding, do NOT save as UTF-8)
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

if not exist "installer\repair.ps1" (
    echo 【错误】找不到 installer\repair.ps1
    echo 最常见原因：直接在压缩包里双击运行了本文件。
    echo 请先把整个压缩包完整解压到文件夹，再重新双击本文件。
    echo 若已解压仍出现此提示：可能是杀毒软件删除了文件，请恢复后重试。
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "installer\repair.ps1"
echo.
echo Repair window closes in 10 seconds...
timeout /t 10 >nul
exit /b %ERRORLEVEL%
