@echo off
rem au3 - run an AutoIt3 script with the 32-bit interpreter.
rem Usage: au3 <script.au3> [script arguments...]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\au3-run.ps1" %*
exit /b %ERRORLEVEL%
