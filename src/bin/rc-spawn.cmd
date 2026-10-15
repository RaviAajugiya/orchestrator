@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\lib\rc-spawn.ps1" %*
exit /b %ERRORLEVEL%
