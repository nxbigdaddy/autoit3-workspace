@echo off
rem au3build - compile an AutoIt3 script into a standalone .exe.
rem Usage: au3build <script.au3> [-Arch x64] [-Type console] [-Out path.exe]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\au3-build.ps1" %*
exit /b %ERRORLEVEL%
