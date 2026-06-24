@echo off
setlocal
set "SCRIPT=%~dp0Unstuck-Command.ps1"
if not exist "%SCRIPT%" (
  echo Missing script: "%SCRIPT%"
  exit /b 1
)
if "%~1"=="" (
  powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%" -Aggressive -RerunDism -IncludeAppReport -IncludeGenericReport -RecoverHungExplorer -RecoverHungTerminalWindows -RecoverHungGenericApps -RecoverStaleTerminalCommands -MaxMonitorSeconds 0
  exit /b %ERRORLEVEL%
)
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
