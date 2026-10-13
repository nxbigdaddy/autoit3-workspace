@echo off
rem aicconsole - 打开 aic（多 Agent 编码调度器）控制台。
rem 优先运行已编译的 exe，没有则用解释器直接运行源码。
rem 可用参数：/demo 造演示环境   /selftest 自检   /home <目录>   /repo <目录>
setlocal
set "EXE=%~dp0..\..\build\AicConsole.exe"
if exist "%EXE%" (
    if "%~1"=="" (
        start "" "%EXE%"
        exit /b 0
    )
    "%EXE%" %*
    exit /b %ERRORLEVEL%
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\au3-run.ps1" -Path "%~dp0..\..\src\AicConsole.au3" %*
exit /b %ERRORLEVEL%
