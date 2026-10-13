@echo off
rem diskreport - 不弹界面，导出磁盘参数与健康报告到 out\diskinfo.txt，并用记事本打开。
setlocal
set "REPORT=%~dp0..\..\out\diskinfo.txt"
if exist "%~dp0..\..\build\DiskInfo.exe" (
    "%~dp0..\..\build\DiskInfo.exe" /report
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\au3-run.ps1" -Path "%~dp0..\..\src\DiskInfo.au3" -ScriptArgs /report
)
if exist "%REPORT%" (
    echo.
    echo 报告已生成: %REPORT%
    start "" notepad "%REPORT%"
) else (
    echo 报告生成失败。
)
exit /b 0
