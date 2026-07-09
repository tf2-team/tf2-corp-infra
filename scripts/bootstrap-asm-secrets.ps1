# Bootstrap AWS Secrets Manager values for SEC-05 cutover.
# Writes CURRENT live credentials only - do not invent new DB passwords.
# Values never go through Terraform.
#
# Usage (from techx-corp-infra):
#   .\scripts\bootstrap-asm-secrets.ps1 -Prefix techx-corp/development -Region us-east-1
#   .\scripts\bootstrap-asm-secrets.ps1 techx-corp/development us-east-1
#
# Env overrides (same as .cmd / .sh):
#   $env:PG_ADMIN_USER, $env:PG_ADMIN_PASSWORD, $env:PG_ADMIN_DB
#   $env:PG_APP_USER, $env:PG_APP_PASSWORD, $env:PG_APP_DB
#   $env:SECRET_KEY_BASE, $env:OPENAI_API_KEY, $env:GRAFANA_USER, $env:GRAFANA_PASSWORD
#
# CMD:  scripts\bootstrap-asm-secrets.cmd ...
# Bash: ./scripts/bootstrap-asm-secrets.sh ...

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Prefix,

    [Parameter(Position = 1)]
    [string] $Region = "us-east-1"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Prefix)) {
    Write-Host "usage: .\scripts\bootstrap-asm-secrets.ps1 -Prefix <name-prefix> [-Region us-east-1]"
    Write-Host "example: .\scripts\bootstrap-asm-secrets.ps1 techx-corp/development us-east-1"
    exit 1
}

# Normalize backslashes from accidental Windows path style
$Prefix = $Prefix.Replace("\", "/")

function Get-EnvOrDefault([string] $Name, [string] $Default) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($v)) { return $Default }
    return $v
}

$pgAdminUser = Get-EnvOrDefault "PG_ADMIN_USER" "root"
$pgAdminPassword = Get-EnvOrDefault "PG_ADMIN_PASSWORD" "otel"
$pgAdminDb = Get-EnvOrDefault "PG_ADMIN_DB" "otel"

$pgAppUser = Get-EnvOrDefault "PG_APP_USER" "otelu"
$pgAppPassword = Get-EnvOrDefault "PG_APP_PASSWORD" "otelp"
$pgAppDb = Get-EnvOrDefault "PG_APP_DB" "otel"

$secretKeyBase = Get-EnvOrDefault "SECRET_KEY_BASE" "yYrECL4qbNwleYInGJYvVnSkwJuSQJ4ijPTx5tirGUXrbznFIBFVJdPl5t6O9ASw"
$openAiApiKey = Get-EnvOrDefault "OPENAI_API_KEY" "dummy"
$grafanaUser = Get-EnvOrDefault "GRAFANA_USER" "admin"
$grafanaPassword = Get-EnvOrDefault "GRAFANA_PASSWORD" "admin"

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Error "AWS CLI not found on PATH."
    exit 1
}

function Put-SecretJson {
    param(
        [string] $SecretId,
        [hashtable] $Data
    )
    Write-Host "Putting secret: $SecretId"
    $json = $Data | ConvertTo-Json -Compress
    $tmp = Join-Path $env:TEMP ("techx-asm-" + [guid]::NewGuid().ToString("n") + ".json")
    try {
        # UTF-8 no BOM
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        & aws secretsmanager put-secret-value `
            --region $Region `
            --secret-id $SecretId `
            --secret-string "file://$tmp"
        if ($LASTEXITCODE -ne 0) {
            throw "put-secret-value failed for $SecretId (exit $LASTEXITCODE)"
        }
    }
    finally {
        if (Test-Path $tmp) { Remove-Item -Force $tmp }
    }
}

Put-SecretJson -SecretId "$Prefix/postgresql-admin" -Data @{
    username = $pgAdminUser
    password = $pgAdminPassword
    database = $pgAdminDb
}

Put-SecretJson -SecretId "$Prefix/postgresql-app" -Data @{
    username = $pgAppUser
    password = $pgAppPassword
    database = $pgAppDb
}

Put-SecretJson -SecretId "$Prefix/flagd-ui" -Data @{
    SECRET_KEY_BASE = $secretKeyBase
}

Put-SecretJson -SecretId "$Prefix/product-reviews" -Data @{
    OPENAI_API_KEY = $openAiApiKey
}

Put-SecretJson -SecretId "$Prefix/grafana" -Data @{
    "admin-user"     = $grafanaUser
    "admin-password" = $grafanaPassword
}

Write-Host "Done. Bootstrap complete for prefix=$Prefix region=$Region"
Write-Host "Next: install ESO + ClusterSecretStore, then helm techx-corp-secrets, wait Ready, then app chart."
