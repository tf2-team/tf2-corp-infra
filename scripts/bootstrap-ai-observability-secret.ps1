# Bootstrap AWS Secrets Manager AI Observability HMAC secret.
#
# Usage:
#   .\scripts\bootstrap-ai-observability-secret.ps1 -Prefix techx-corp/development -Region us-east-1
#

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Prefix,

    [Parameter(Position = 1)]
    [string] $Region = "us-east-1",

    [Parameter(Position = 2)]
    [string] $HmacKey = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Prefix)) {
    Write-Host "usage: .\scripts\bootstrap-ai-observability-secret.ps1 -Prefix <name-prefix> [-Region us-east-1] [-HmacKey <32+ bytes key>]"
    Write-Host "example: .\scripts\bootstrap-ai-observability-secret.ps1 techx-corp/development us-east-1"
    exit 1
}

$Prefix = $Prefix.Replace("\", "/")

if ([string]::IsNullOrEmpty($HmacKey)) {
    $HmacKey = [Environment]::GetEnvironmentVariable("AI_OBSERVABILITY_HMAC_KEY")
}

if ([string]::IsNullOrEmpty($HmacKey)) {
    $bytes = New-Object byte[] 32
    (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($bytes)
    $HmacKey = -join ($bytes | ForEach-Object { $_.ToString("x2") })
}

if ([System.Text.Encoding]::UTF8.GetByteCount($HmacKey) -lt 32) {
    Write-Error "AI_OBSERVABILITY_HMAC_KEY must be at least 32 bytes long"
    exit 1
}

$secretName = "$Prefix/ai-observability"
$payload = @{
    AI_OBSERVABILITY_HMAC_KEY = $HmacKey
} | ConvertTo-Json -Compress

Write-Host "Writing secret: $secretName in region $Region..."
aws secretsmanager put-secret-value --secret-id $secretName --secret-string $payload --region $Region

# Change trail: @hungxqt - 2026-07-29 - Created bootstrap script for AI Observability HMAC secret.
