@echo off
setlocal EnableExtensions

REM Bootstrap AWS Secrets Manager AIOps live executor secret.
REM Preserves the existing token when present and only adds/updates approval_id.
REM Usage:
REM   scripts\bootstrap-aiops-live-executor-secret.cmd techx-corp/production us-east-1 adr-live-001

if "%~1"=="" (
  echo usage: %~nx0 name-prefix [region] approval-id [token]
  echo example: %~nx0 techx-corp/production us-east-1 adr-live-001
  exit /b 1
)

set "PREFIX=%~1"
if "%~2"=="" (
  set "REGION=us-east-1"
) else (
  set "REGION=%~2"
)

set "APPROVAL_ID=%~3"
set "TOKEN=%~4"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap-aiops-live-executor-secret.ps1" -Prefix "%PREFIX%" -Region "%REGION%" -ApprovalId "%APPROVAL_ID%" -Token "%TOKEN%"
exit /b %ERRORLEVEL%

REM Change trail: @hungxqt - 2026-07-29 - Created CMD entry point for AIOps live executor bootstrap.
