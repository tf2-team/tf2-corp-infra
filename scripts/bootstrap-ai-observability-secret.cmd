@echo off
setlocal EnableExtensions

REM Bootstrap AWS Secrets Manager AI Observability HMAC secret.
REM Usage:
REM   scripts\bootstrap-ai-observability-secret.cmd techx-corp/development [region] [hmac-key]
REM   scripts\bootstrap-ai-observability-secret.cmd techx-corp/production us-east-1

if "%~1"=="" (
  echo usage: %~nx0 name-prefix [region] [hmac-key]
  echo example: %~nx0 techx-corp/development us-east-1
  exit /b 1
)

set "PREFIX=%~1"
if "%~2"=="" (
  set "REGION=us-east-1"
) else (
  set "REGION=%~2"
)

set "KEY=%~3"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap-ai-observability-secret.ps1" -Prefix "%PREFIX%" -Region "%REGION%" -HmacKey "%KEY%"
exit /b %ERRORLEVEL%
REM Change trail: @hungxqt - 2026-07-29 - Created CMD entry point for AI Observability secret bootstrap.
