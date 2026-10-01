@echo off
rem ============================================================
rem  Folder Icon Tool - launcher
rem  Starts the GUI without showing a console window.
rem ============================================================
set "SCRIPT=%~dp0FolderIconTool.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] FolderIconTool.ps1 not found next to this launcher.
    pause
    exit /b 1
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%" %*
exit /b 0
