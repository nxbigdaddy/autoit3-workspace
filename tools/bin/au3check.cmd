@echo off
rem au3check - syntax-check AutoIt3 scripts with Au3Check.
rem Usage: au3check <script.au3 | folder> [more files...]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\au3-check.ps1" %*
exit /b %ERRORLEVEL%
