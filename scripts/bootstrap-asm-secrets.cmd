@echo off
setlocal EnableExtensions

REM Bootstrap AWS Secrets Manager values for SEC-05 cutover.
REM Prefer PowerShell script on Windows - this .cmd delegates to it so JSON stays valid.
REM
REM Usage:
REM   scripts\bootstrap-asm-secrets.cmd techx-corp/development us-east-1
REM   scripts\bootstrap-asm-secrets.cmd techx-corp/production us-east-1
REM
REM Better:  powershell -File scripts\bootstrap-asm-secrets.ps1 ...
REM Bash:    ./scripts/bootstrap-asm-secrets.sh ...

if "%~1"=="" (
  echo usage: %~nx0 name-prefix [region]
  echo example: %~nx0 techx-corp/development us-east-1
  exit /b 1
)

set "PREFIX=%~1"
if "%~2"=="" (
  set "REGION=us-east-1"
) else (
  set "REGION=%~2"
)

REM Delegate to PowerShell (ConvertTo-Json) - raw cmd echo previously wrote empty/invalid JSON
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap-asm-secrets.ps1" -Prefix "%PREFIX%" -Region "%REGION%"
exit /b %ERRORLEVEL%
