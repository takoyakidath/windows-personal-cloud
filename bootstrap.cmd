@echo off
rem Windows Personal Cloud - double-click to set up this PC.
rem Elevates itself, then runs bootstrap.ps1 next to this file (no "irm | iex", no typing).
setlocal
fltmc >nul 2>&1
if errorlevel 1 (
  echo Requesting Administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath %~f0 -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap.ps1"
echo.
echo Finished with exit code %errorlevel%. You can close this window.
pause
