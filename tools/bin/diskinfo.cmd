@echo off
rem diskinfo - 打开“磁盘参数与健康检测”图形界面。
rem 优先运行已编译的 exe，没有则用解释器直接运行源码。
setlocal
set "EXE=%~dp0..\..\build\DiskInfo.exe"
if exist "%EXE%" (
    start "" "%EXE%"
    exit /b 0
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\au3-run.ps1" -Path "%~dp0..\..\src\DiskInfo.au3" %*
exit /b %ERRORLEVEL%
