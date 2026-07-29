# Bootstrap AWS Secrets Manager AIOps live executor secret.
# Preserves the existing token when present and only adds/updates approval_id.
#
# Usage:
#   .\scripts\bootstrap-aiops-live-executor-secret.ps1 techx-corp/production us-east-1 adr-live-001

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Prefix,

    [Parameter(Position = 1)]
    [string] $Region = "us-east-1",

    [Parameter(Position = 2)]
    [string] $ApprovalId = "",

    [Parameter(Position = 3)]
    [string] $Token = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Prefix)) {
    Write-Host "usage: .\scripts\bootstrap-aiops-live-executor-secret.ps1 <name-prefix> [region] <approval-id> [token]"
    Write-Host "example: .\scripts\bootstrap-aiops-live-executor-secret.ps1 techx-corp/production us-east-1 adr-live-001"
    exit 1
}

$Prefix = $Prefix.Replace("\", "/")

if ([string]::IsNullOrWhiteSpace($ApprovalId)) {
    $ApprovalId = [Environment]::GetEnvironmentVariable("AIOPS_LIVE_EXECUTOR_APPROVAL_ID")
}

if ([string]::IsNullOrWhiteSpace($ApprovalId)) {
    Write-Error "approval-id is required. Pass it as arg 3 or AIOPS_LIVE_EXECUTOR_APPROVAL_ID."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    $Token = [Environment]::GetEnvironmentVariable("AIOPS_LIVE_EXECUTOR_TOKEN")
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Error "AWS CLI not found on PATH."
    exit 1
}

$secretName = "$Prefix/aiops-live-executor-token"

if ([string]::IsNullOrWhiteSpace($Token)) {
    try {
        $existingSecret = & aws secretsmanager get-secret-value `
            --region $Region `
            --secret-id $secretName `
            --query SecretString `
            --output text 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existingSecret) -and $existingSecret -ne "None") {
            $existingPayload = $existingSecret | ConvertFrom-Json
            if ($existingPayload.PSObject.Properties.Name -contains "token") {
                $Token = [string] $existingPayload.token
            }
        }
    }
    catch {
        $Token = ""
    }
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    $bytes = New-Object byte[] 32
    (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($bytes)
    $Token = -join ($bytes | ForEach-Object { $_.ToString("x2") })
    Write-Host "Generated new executor token because no existing token was found."
}
else {
    Write-Host "Preserving existing executor token."
}

$payload = @{
    token       = $Token
    approval_id = $ApprovalId
} | ConvertTo-Json -Compress

$tmp = Join-Path $env:TEMP ("techx-aiops-live-executor-" + [guid]::NewGuid().ToString("n") + ".json")
try {
    [System.IO.File]::WriteAllText($tmp, $payload, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Writing secret: $secretName in region $Region..."
    & aws secretsmanager put-secret-value `
        --region $Region `
        --secret-id $secretName `
        --secret-string "file://$tmp" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "put-secret-value failed for $secretName (exit $LASTEXITCODE)"
    }
}
finally {
    if (Test-Path $tmp) { Remove-Item -Force $tmp }
}

Write-Host "Done. AIOps live executor secret now contains token and approval_id."

# Change trail: @hungxqt - 2026-07-29 - Add AIOps live executor approval bootstrap.
