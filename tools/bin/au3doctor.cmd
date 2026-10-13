@echo off
rem au3doctor - read-only health check of the AutoIt3 environment.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\env-doctor.ps1" %*
exit /b %ERRORLEVEL%
