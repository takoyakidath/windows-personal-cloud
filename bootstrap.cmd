@echo off
rem Windows Personal Cloud - double-click to set up this PC.
rem Elevates itself, then runs bootstrap.ps1 next to this file (no "irm | iex", no typing).
setlocal
rem The path is quoted below: it may contain spaces or brackets, e.g. "windows-personal-cloud-main (1)".
rem No round brackets in comments inside the if-block: cmd would end the block there.
fltmc >nul 2>&1
if errorlevel 1 (
  echo Requesting Administrator rights...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  if errorlevel 1 (
    echo Could not get Administrator rights. Right-click bootstrap.cmd and choose "Run as administrator".
    pause
  )
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap.ps1"
echo.
echo Finished with exit code %errorlevel%. You can close this window.
pause
