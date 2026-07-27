#Requires -Version 5.1

<#
.SYNOPSIS
Runs the TechX Directive 20 formal DynamoDB controlled-loss PITR drill.

.DESCRIPTION
Without -Execute, this script performs read-only preflight checks only.
With -Execute, it:
  1. Writes one synthetic marker with status=drill-hold to the production outbox.
  2. Confirms the marker and its SHA-256.
  3. Deletes only that marker with a prefix/hash condition.
  4. Restores the production table to a new isolated table at T_safe.
  5. Validates the restored payload/hash and measures RPO/RTO.
  6. Verifies that production was not overwritten and remains healthy.

The script never deletes the isolated restore target. Keep it for mentor
inspection and clean it up later through a separately approved change.

.EXAMPLE
.\mandate-20-dynamodb-drill.ps1

Runs read-only preflight checks.

.EXAMPLE
.\mandate-20-dynamodb-drill.ps1 -Execute

Runs the real controlled-loss restore drill after interactive confirmations.
#>

[CmdletBinding()]
param(
    [switch]$Execute,
    [string]$Region = "us-east-1",
    [string]$ExpectedAccount = "493499579600",
    [string]$SourceTable = "techx-prod-tf2-checkout-outbox",
    [string]$StorefrontUrl = "https://shop.hungtran.id.vn",
    [string]$ArgoApplication = "techx-corp",
    [string]$ApplicationNamespace = "techx-corp-prod",
    [string]$EvidenceRoot = "",
    [int]$RpoTargetSeconds = 600,
    [int]$RtoTargetMinutes = 30,
    [int]$PollSeconds = 15,
    [int]$MaxPitrWaitMinutes = 30,
    [int]$MaxRestoreWaitMinutes = 60,
    [int]$MaxClockSkewSeconds = 30
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor Cyan
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    [IO.File]::WriteAllText(
        $Path,
        $Content,
        [Text.UTF8Encoding]::new($false)
    )
}

function Invoke-NativeJson {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowEmpty,
        [switch]$ShowRaw
    )

    $nativeOutput = & $Command @Arguments 2>&1
    $nativeExitCode = $LASTEXITCODE
    $nativeText = ($nativeOutput | Out-String).Trim()

    if ($ShowRaw -and -not [string]::IsNullOrWhiteSpace($nativeText)) {
        Write-Host $nativeText
    }

    if ($nativeExitCode -ne 0) {
        throw "$Command failed with exit code ${nativeExitCode}: $nativeText"
    }

    if ([string]::IsNullOrWhiteSpace($nativeText)) {
        if ($AllowEmpty) {
            # AWS CLI may emit no JSON at all for successful operations such as
            # delete-item and get-item when the requested item is absent. Keep a
            # stable Item property so StrictMode callers can serialize evidence
            # and test absence without raising a missing-property exception.
            return [pscustomobject]@{ Item = $null }
        }
        throw "$Command returned empty output"
    }

    try {
        return $nativeText | ConvertFrom-Json
    }
    catch {
        throw "Cannot parse JSON returned by $Command`: $nativeText"
    }
}

function Invoke-AwsJson {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowEmpty,
        [switch]$ShowRaw
    )

    $awsArguments = @($Arguments) + @("--no-cli-pager", "--output", "json")
    return Invoke-NativeJson `
        -Command "aws" `
        -Arguments $awsArguments `
        -AllowEmpty:$AllowEmpty `
        -ShowRaw:$ShowRaw
}

function Invoke-KubectlJson {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$ShowRaw
    )

    $kubectlArguments = @($Arguments) + @("-o", "json")
    return Invoke-NativeJson `
        -Command "kubectl" `
        -Arguments $kubectlArguments `
        -ShowRaw:$ShowRaw
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Value)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
        return ([BitConverter]::ToString($bytes)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Assert-Storefront {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Phase
    )

    $response = Invoke-WebRequest `
        -Uri $Url `
        -Method Get `
        -UseBasicParsing `
        -TimeoutSec 30

    $statusCode = [int]$response.StatusCode
    Write-Host "${Phase}StorefrontHTTP=$statusCode"

    if ($statusCode -lt 200 -or $statusCode -ge 400) {
        throw "$Phase storefront check failed: HTTP $statusCode"
    }

    return $statusCode
}

function Assert-KubernetesHealth {
    param([Parameter(Mandatory = $true)][string]$Phase)

    $application = Invoke-KubectlJson -Arguments @(
        "-n", "argocd",
        "get", "application", $ArgoApplication
    )

    $syncStatus = [string]$application.status.sync.status
    $healthStatus = [string]$application.status.health.status
    Write-Host "${Phase}ArgoSync=$syncStatus"
    Write-Host "${Phase}ArgoHealth=$healthStatus"
    Write-Utf8NoBom `
        -Path (Join-Path $evidenceDir ("k8s-" + $Phase.ToLowerInvariant() + "-argo.json")) `
        -Content ($application | ConvertTo-Json -Depth 30)

    if ($syncStatus -ne "Synced" -or $healthStatus -ne "Healthy") {
        throw "$Phase Argo application is not Synced/Healthy"
    }

    foreach ($deploymentName in @("checkout", "flagd")) {
        $deployment = Invoke-KubectlJson -Arguments @(
            "-n", $ApplicationNamespace,
            "get", "deployment", $deploymentName
        )

        $desired = [int]$deployment.spec.replicas
        $ready = [int]$deployment.status.readyReplicas
        Write-Host "${Phase}-${deploymentName}-Ready=$ready/$desired"
        Write-Utf8NoBom `
            -Path (Join-Path $evidenceDir ("k8s-" + $Phase.ToLowerInvariant() + "-" + $deploymentName + ".json")) `
            -Content ($deployment | ConvertTo-Json -Depth 30)

        if ($ready -ne $desired) {
            throw "$Phase deployment $deploymentName is not fully ready"
        }
    }
}

function Assert-TargetAbsent {
    param([Parameter(Mandatory = $true)][string]$TargetTable)

    $tables = Invoke-AwsJson -Arguments @(
        "dynamodb", "list-tables",
        "--region", $Region
    )

    if (@($tables.TableNames) -contains $TargetTable) {
        throw "ABORT: target table already exists: $TargetTable"
    }

    Write-Host "TargetAbsent=$TargetTable"
}

function Get-AwsServiceUtc {
    $response = $null
    try {
        $response = Invoke-WebRequest `
            -Uri "https://dynamodb.$Region.amazonaws.com/" `
            -Method Head `
            -UseBasicParsing `
            -TimeoutSec 30
    }
    catch {
        # An unsigned request is expected to return 4xx; AWS still supplies its
        # authoritative HTTP Date header on that response.
        $response = $_.Exception.Response
    }

    if ($null -eq $response) {
        throw "Cannot obtain the DynamoDB service clock"
    }

    $dateHeader = [string]$response.Headers["Date"]
    if ([string]::IsNullOrWhiteSpace($dateHeader)) {
        throw "DynamoDB response did not contain an HTTP Date header"
    }

    return ([DateTimeOffset]::Parse(
        $dateHeader,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    )).UtcDateTime
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw "AWS CLI was not found. Run this file from Windows PowerShell/PowerShell 7 with AWS CLI installed."
}
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw "kubectl was not found."
}

if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    $EvidenceRoot = $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    $EvidenceRoot = (Get-Location).Path
}

$runId = Get-Date -Format "yyyyMMddHHmmss"
$markerId = "m20-drill-$runId"
$targetTable = "m20-drill-outbox-$runId"
$payload = "mandate20-restore-proof-$runId"
$payloadHash = Get-Sha256Hex -Value $payload
$createdEpochMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$evidenceDir = Join-Path $EvidenceRoot ("m20-dynamodb-evidence-" + (Get-Date -Format "yyyyMMdd-HHmmss"))

New-Item -ItemType Directory -Path $evidenceDir -ErrorAction Stop | Out-Null
$transcriptPath = Join-Path $evidenceDir "mandate20-drill-transcript.txt"
$transcriptStarted = $false
$markerInserted = $false
$markerDeleted = $false
$restoreRequested = $false
$drillCompleted = $false

try {
    Start-Transcript -Path $transcriptPath -ErrorAction Stop | Out-Null
    $transcriptStarted = $true

    $runMode = "PREFLIGHT-ONLY"
    if ($Execute) {
        $runMode = "EXECUTE"
    }

    Write-Step "MANDATE 20 — RUN CONTEXT"
    Write-Host "Mode=$runMode"
    Write-Host "Region=$Region"
    Write-Host "ExpectedAccount=$ExpectedAccount"
    Write-Host "SourceTable=$SourceTable"
    Write-Host "MarkerId=$markerId"
    Write-Host "TargetTable=$targetTable"
    Write-Host "EvidenceDir=$evidenceDir"

    Write-Step "1. READ-ONLY PREFLIGHT"

    $identity = Invoke-AwsJson -Arguments @("sts", "get-caller-identity")
    if ([string]$identity.Account -ne $ExpectedAccount) {
        throw "Wrong AWS account: $($identity.Account)"
    }
    Write-Host "CallerArn=$($identity.Arn)"
    Write-Host "AccountCheck=PASS"

    $awsServiceUtc = Get-AwsServiceUtc
    $localClockSkewSeconds = ([DateTime]::UtcNow - $awsServiceUtc).TotalSeconds
    Write-Host "AwsServiceUTC=$($awsServiceUtc.ToString('o'))"
    Write-Host "LocalClockSkewSeconds=$([math]::Round($localClockSkewSeconds, 2))"
    if ([math]::Abs($localClockSkewSeconds) -gt $MaxClockSkewSeconds) {
        throw "Local clock skew exceeds $MaxClockSkewSeconds seconds"
    }
    Write-Host "ClockSkewCheck=PASS"

    $sourceDescription = Invoke-AwsJson -Arguments @(
        "dynamodb", "describe-table",
        "--region", $Region,
        "--table-name", $SourceTable
    )
    Write-Utf8NoBom `
        -Path (Join-Path $evidenceDir "preflight-source-table.json") `
        -Content ($sourceDescription | ConvertTo-Json -Depth 20)

    if ([string]$sourceDescription.Table.TableStatus -ne "ACTIVE") {
        throw "Source table is not ACTIVE"
    }

    $gsiNames = @($sourceDescription.Table.GlobalSecondaryIndexes | ForEach-Object {
        $_.IndexName
    })
    if ($gsiNames -notcontains "status-created-index") {
        throw "Source table is missing status-created-index"
    }

    Write-Host "SourceStatus=$($sourceDescription.Table.TableStatus)"
    Write-Host "SourceKmsStatus=$($sourceDescription.Table.SSEDescription.Status)"
    Write-Host "SourceGSI=$($gsiNames -join ',')"

    $continuousBackups = Invoke-AwsJson -Arguments @(
        "dynamodb", "describe-continuous-backups",
        "--region", $Region,
        "--table-name", $SourceTable
    )
    Write-Utf8NoBom `
        -Path (Join-Path $evidenceDir "preflight-pitr.json") `
        -Content ($continuousBackups | ConvertTo-Json -Depth 10)

    $pitr = $continuousBackups.ContinuousBackupsDescription.PointInTimeRecoveryDescription
    if ([string]$pitr.PointInTimeRecoveryStatus -ne "ENABLED") {
        throw "DynamoDB PITR is not ENABLED"
    }

    Write-Host "PITRStatus=$($pitr.PointInTimeRecoveryStatus)"
    Write-Host "PITRRecoveryDays=$($pitr.RecoveryPeriodInDays)"
    Write-Host "EarliestRestorable=$($pitr.EarliestRestorableDateTime)"
    Write-Host "LatestRestorable=$($pitr.LatestRestorableDateTime)"

    Assert-TargetAbsent -TargetTable $targetTable
    Assert-KubernetesHealth -Phase "Before"
    $storefrontBefore = Assert-Storefront -Url $StorefrontUrl -Phase "Before"

    Write-Host "Preflight=PASS" -ForegroundColor Green

    if (-not $Execute) {
        Write-Step "PREFLIGHT COMPLETE — NO WRITE OR RESTORE WAS PERFORMED"
        Write-Host "Run the real drill only in the approved mentor window:"
        Write-Host ".\mandate-20-dynamodb-drill.ps1 -Execute"
        return
    }

    Write-Step "2. EXECUTION AUTHORIZATION"
    Write-Warning "This will write and delete ONE synthetic marker in the production DynamoDB source."
    Write-Warning "It will then create a NEW isolated PITR target. It will NOT overwrite production."
    Write-Host "Required confirmation: EXECUTE $markerId" -ForegroundColor Yellow

    $executionConfirmation = Read-Host "Type the required confirmation"
    if ($executionConfirmation -ne "EXECUTE $markerId") {
        throw "ABORT: execution confirmation did not match"
    }

    Write-Step "3. INSERT SYNTHETIC MARKER"

    $item = @{
        event_id      = @{ S = $markerId }
        status        = @{ S = "drill-hold" }
        created_at    = @{ N = "$createdEpochMs" }
        payload       = @{ S = $payload }
        payload_sha256 = @{ S = $payloadHash }
    }

    $itemPath = Join-Path $evidenceDir "marker-item.json"
    Write-Utf8NoBom `
        -Path $itemPath `
        -Content ($item | ConvertTo-Json -Depth 5 -Compress)

    Invoke-AwsJson -AllowEmpty -Arguments @(
        "dynamodb", "put-item",
        "--region", $Region,
        "--table-name", $SourceTable,
        "--item", "file://$itemPath",
        "--condition-expression", "attribute_not_exists(event_id)"
    ) | Out-Null
    $markerInserted = $true

    $key = @{
        event_id = @{ S = $markerId }
    }
    $keyPath = Join-Path $evidenceDir "marker-key.json"
    Write-Utf8NoBom `
        -Path $keyPath `
        -Content ($key | ConvertTo-Json -Depth 3 -Compress)

    $inserted = Invoke-AwsJson -Arguments @(
        "dynamodb", "get-item",
        "--region", $Region,
        "--table-name", $SourceTable,
        "--key", "file://$keyPath",
        "--consistent-read"
    )
    Write-Utf8NoBom `
        -Path (Join-Path $evidenceDir "inserted-item.json") `
        -Content ($inserted | ConvertTo-Json -Depth 10)

    if (-not $inserted.Item) {
        throw "Marker was not found after put-item"
    }
    if ([string]$inserted.Item.status.S -ne "drill-hold") {
        throw "Marker status is not drill-hold"
    }
    if ([string]$inserted.Item.payload_sha256.S -ne $payloadHash) {
        throw "Marker hash mismatch before controlled loss"
    }

    Write-Host "MarkerInserted=PASS"
    Write-Host "Payload=$payload"
    Write-Host "ExpectedSHA256=$payloadHash"
    Write-Host "SafetyContract=status drill-hold is outside worker query status=pending"

    Write-Step "4. SELECT T_safe AND WAIT FOR CONFIRMED PITR COVERAGE"
    Start-Sleep -Seconds 2
    $safeUtc = Get-AwsServiceUtc
    $safeRestoreTimestamp = $safeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $safeRestoreUtc = [DateTime]::Parse(
        $safeRestoreTimestamp,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    ).ToUniversalTime()

    Write-Host "T_safe=$safeRestoreTimestamp"

    # Keep the marker in the source until DynamoDB itself reports that T_safe is
    # restorable. This removes workstation clock skew and asynchronous PITR lag
    # from the integrity assumption: the marker cannot be deleted before the
    # selected recovery point is confirmed available by the provider.
    $pitrDeadline = [DateTime]::UtcNow.AddMinutes($MaxPitrWaitMinutes)
    do {
        $continuousBackups = Invoke-AwsJson -Arguments @(
            "dynamodb", "describe-continuous-backups",
            "--region", $Region,
            "--table-name", $SourceTable
        )

        $pitr = $continuousBackups.ContinuousBackupsDescription.PointInTimeRecoveryDescription
        if ([string]$pitr.PointInTimeRecoveryStatus -ne "ENABLED") {
            throw "PITR was disabled during the drill"
        }

        $latestRestorableUtc = ([DateTimeOffset]$pitr.LatestRestorableDateTime).UtcDateTime
        Write-Host "$(Get-Date -Format o) LatestRestorableUTC=$($latestRestorableUtc.ToString('o'))"

        if ($latestRestorableUtc -lt $safeRestoreUtc) {
            if ([DateTime]::UtcNow -ge $pitrDeadline) {
                throw "PITR did not cover T_safe within $MaxPitrWaitMinutes minutes"
            }
            Start-Sleep -Seconds $PollSeconds
        }
    } while ($latestRestorableUtc -lt $safeRestoreUtc)

    $pitrCoveredUtc = Get-AwsServiceUtc
    $pitrAvailabilityLagMinutes = ($pitrCoveredUtc - $safeRestoreUtc).TotalMinutes
    Write-Host "PITRAvailabilityLagMinutes=$([math]::Round($pitrAvailabilityLagMinutes, 2))"

    $coveredMarker = Invoke-AwsJson -Arguments @(
        "dynamodb", "get-item",
        "--region", $Region,
        "--table-name", $SourceTable,
        "--key", "file://$keyPath",
        "--consistent-read"
    )
    Write-Utf8NoBom `
        -Path (Join-Path $evidenceDir "pitr-covered-marker.json") `
        -Content ($coveredMarker | ConvertTo-Json -Depth 10)

    if (-not $coveredMarker.Item) {
        throw "PITR COVERAGE FAILED: marker disappeared before controlled loss"
    }
    if ([string]$coveredMarker.Item.payload_sha256.S -ne $payloadHash) {
        throw "PITR COVERAGE FAILED: marker hash changed before controlled loss"
    }

    Write-Host "PITRCoverage=PASS" -ForegroundColor Green

    Write-Step "5. CONTROLLED LOSS CONFIRMATION"
    Write-Host "PITR covers T_safe and the marker is still present." -ForegroundColor Yellow
    Write-Host "Type the exact marker ID immediately before controlled deletion:" -ForegroundColor Yellow
    Write-Host $markerId -ForegroundColor Yellow
    $deleteConfirmation = Read-Host "MarkerId"
    if ($deleteConfirmation -ne $markerId) {
        throw "ABORT: controlled delete confirmation did not match"
    }

    $expressionValues = @{
        ":prefix"   = @{ S = "m20-drill-" }
        ":expected" = @{ S = $payloadHash }
    }
    $expressionPath = Join-Path $evidenceDir "delete-expression-values.json"
    Write-Utf8NoBom `
        -Path $expressionPath `
        -Content ($expressionValues | ConvertTo-Json -Depth 4 -Compress)

    $deleteRequestUtc = [DateTime]::UtcNow
    Invoke-AwsJson -AllowEmpty -Arguments @(
        "dynamodb", "delete-item",
        "--region", $Region,
        "--table-name", $SourceTable,
        "--key", "file://$keyPath",
        "--condition-expression", "begins_with(event_id, :prefix) AND payload_sha256 = :expected",
        "--expression-attribute-values", "file://$expressionPath"
    ) | Out-Null
    $lossUtc = Get-AwsServiceUtc
    $markerDeleted = $true

    Write-Host "T_delete_request=$($deleteRequestUtc.ToString('o'))"
    Write-Host "T_loss=$($lossUtc.ToString('o'))"

    $deletedCheck = Invoke-AwsJson -AllowEmpty -Arguments @(
        "dynamodb", "get-item",
        "--region", $Region,
        "--table-name", $SourceTable,
        "--key", "file://$keyPath",
        "--consistent-read"
    )
    Write-Utf8NoBom `
        -Path (Join-Path $evidenceDir "deleted-check.json") `
        -Content ($deletedCheck | ConvertTo-Json -Depth 10)

    if ($deletedCheck.Item) {
        throw "CONTROLLED LOSS FAILED: marker still exists in source"
    }

    $actualRpoSeconds = ($lossUtc - $safeRestoreUtc).TotalSeconds
    Write-Host "ActualRPOSeconds=$([math]::Round($actualRpoSeconds, 2))"
    Write-Host "RPOTargetSeconds=$RpoTargetSeconds"

    if ($actualRpoSeconds -lt 0 -or $actualRpoSeconds -gt $RpoTargetSeconds) {
        throw "RPO FAILED: $actualRpoSeconds seconds"
    }

    Write-Host "ControlledLoss=PASS" -ForegroundColor Green
    Write-Host "RPO=PASS" -ForegroundColor Green

    Write-Step "6. RESTORE TO ISOLATED TARGET"

    Assert-TargetAbsent -TargetTable $targetTable

    $restoreStartUtc = [DateTime]::UtcNow
    Write-Host "T_restore_start=$($restoreStartUtc.ToString('o'))"

    $restoreResponse = Invoke-AwsJson -Arguments @(
        "dynamodb", "restore-table-to-point-in-time",
        "--region", $Region,
        "--source-table-name", $SourceTable,
        "--target-table-name", $targetTable,
        "--restore-date-time", $safeRestoreTimestamp
    )
    $restoreRequested = $true
    Write-Utf8NoBom `
        -Path (Join-Path $evidenceDir "restore-request.json") `
        -Content ($restoreResponse | ConvertTo-Json -Depth 20)

    $restoreDeadline = $restoreStartUtc.AddMinutes($MaxRestoreWaitMinutes)
    do {
        Start-Sleep -Seconds $PollSeconds
        $targetDescription = Invoke-AwsJson -Arguments @(
            "dynamodb", "describe-table",
            "--region", $Region,
            "--table-name", $targetTable
        )
        $targetStatus = [string]$targetDescription.Table.TableStatus
        Write-Host "$(Get-Date -Format o) TargetStatus=$targetStatus"

        if ($targetStatus -ne "ACTIVE" -and [DateTime]::UtcNow -ge $restoreDeadline) {
            throw "Target did not become ACTIVE within $MaxRestoreWaitMinutes minutes"
        }
    } while ($targetStatus -ne "ACTIVE")

    Write-Step "7. RESTORED DATA INTEGRITY"

    $restored = Invoke-AwsJson -Arguments @(
        "dynamodb", "get-item",
        "--region", $Region,
        "--table-name", $targetTable,
        "--key", "file://$keyPath",
        "--consistent-read"
    )
    Write-Utf8NoBom `
        -Path (Join-Path $evidenceDir "restored-item.json") `
        -Content ($restored | ConvertTo-Json -Depth 10)

    if (-not $restored.Item) {
        throw "INTEGRITY FAILED: marker not found in restored target"
    }

    $restoredPayload = [string]$restored.Item.payload.S
    $restoredDeclaredHash = [string]$restored.Item.payload_sha256.S
    $restoredComputedHash = Get-Sha256Hex -Value $restoredPayload

    Write-Host "RestoredPayload=$restoredPayload"
    Write-Host "RestoredDeclaredHash=$restoredDeclaredHash"
    Write-Host "RestoredComputedHash=$restoredComputedHash"
    Write-Host "ExpectedHash=$payloadHash"

    if ($restoredPayload -ne $payload) {
        throw "INTEGRITY FAILED: payload mismatch"
    }
    if ($restoredDeclaredHash -ne $payloadHash) {
        throw "INTEGRITY FAILED: declared hash mismatch"
    }
    if ($restoredComputedHash -ne $payloadHash) {
        throw "INTEGRITY FAILED: computed hash mismatch"
    }

    $integrityConfirmedUtc = [DateTime]::UtcNow
    $actualRtoMinutes = ($integrityConfirmedUtc - $restoreStartUtc).TotalMinutes
    $endToEndRecoveryMinutes = ($integrityConfirmedUtc - $lossUtc).TotalMinutes

    Write-Host "T_integrity_confirmed=$($integrityConfirmedUtc.ToString('o'))"
    Write-Host "ActualRTOMinutes=$([math]::Round($actualRtoMinutes, 2))"
    Write-Host "EndToEndRecoveryMinutes=$([math]::Round($endToEndRecoveryMinutes, 2))"
    Write-Host "RTOTargetMinutes=$RtoTargetMinutes"

    $rtoPassed = $actualRtoMinutes -le $RtoTargetMinutes

    Write-Step "8. VERIFY PRODUCTION WAS NOT OVERWRITTEN"

    $sourceAfter = Invoke-AwsJson -AllowEmpty -Arguments @(
        "dynamodb", "get-item",
        "--region", $Region,
        "--table-name", $SourceTable,
        "--key", "file://$keyPath",
        "--consistent-read"
    )
    Write-Utf8NoBom `
        -Path (Join-Path $evidenceDir "source-after-restore.json") `
        -Content ($sourceAfter | ConvertTo-Json -Depth 10)

    if ($sourceAfter.Item) {
        throw "PRODUCTION CHECK FAILED: source marker unexpectedly exists"
    }

    $targetDescription = Invoke-AwsJson -Arguments @(
        "dynamodb", "describe-table",
        "--region", $Region,
        "--table-name", $targetTable
    )
    Write-Host "IsolatedTargetArn=$($targetDescription.Table.TableArn)"
    Write-Host "IsolatedTargetStatus=$($targetDescription.Table.TableStatus)"
    Write-Host "IsolatedTargetKmsStatus=$($targetDescription.Table.SSEDescription.Status)"

    Assert-KubernetesHealth -Phase "After"
    $storefrontAfter = Assert-Storefront -Url $StorefrontUrl -Phase "After"

    Write-Step "9. CLOUDTRAIL RESTORE EVIDENCE"

    try {
        $cloudTrail = Invoke-AwsJson -Arguments @(
            "cloudtrail", "lookup-events",
            "--region", $Region,
            "--lookup-attributes", "AttributeKey=EventName,AttributeValue=RestoreTableToPointInTime",
            "--max-results", "20"
        )

        $matchingEvents = @($cloudTrail.Events | Where-Object {
            [string]$_.CloudTrailEvent -like "*$targetTable*"
        })

        foreach ($event in $matchingEvents) {
            if ($event.PSObject.Properties.Name -contains "AccessKeyId") {
                $event.AccessKeyId = "[REDACTED]"
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$event.CloudTrailEvent)) {
                try {
                    $eventDetail = $event.CloudTrailEvent | ConvertFrom-Json
                    if ($null -ne $eventDetail.userIdentity -and
                        $eventDetail.userIdentity.PSObject.Properties.Name -contains "accessKeyId") {
                        $eventDetail.userIdentity.accessKeyId = "[REDACTED]"
                    }
                    if ($eventDetail.PSObject.Properties.Name -contains "sourceIPAddress") {
                        $eventDetail.sourceIPAddress = "[REDACTED]"
                    }
                    $event.CloudTrailEvent = $eventDetail | ConvertTo-Json -Depth 20 -Compress
                }
                catch {
                    Write-Warning "CloudTrail detail redaction failed; omitting raw event detail."
                    $event.CloudTrailEvent = "[REDACTED]"
                }
            }
        }

        Write-Host "MatchingRestoreEvents=$($matchingEvents.Count)"
        Write-Utf8NoBom `
            -Path (Join-Path $evidenceDir "cloudtrail-restore-events.json") `
            -Content ($matchingEvents | ConvertTo-Json -Depth 10)
    }
    catch {
        Write-Warning "CloudTrail lookup did not complete: $($_.Exception.Message)"
        Write-Warning "The restore API response and transcript remain primary drill evidence."
    }

    $resultText = "FAIL"
    if ($rtoPassed) {
        $resultText = "PASS"
    }
    $result = [pscustomobject]@{
        SourceTable                = $SourceTable
        IsolatedTarget             = $targetTable
        MarkerId                   = $markerId
        SafeTimeUtc                = $safeRestoreTimestamp
        LossTimeUtc                = $lossUtc.ToString("o")
        ActualRpoSeconds           = [math]::Round($actualRpoSeconds, 2)
        RpoTargetSeconds           = $RpoTargetSeconds
        PitrAvailabilityLagMinutes = [math]::Round($pitrAvailabilityLagMinutes, 2)
        RestoreStartUtc            = $restoreStartUtc.ToString("o")
        IntegrityConfirmedUtc      = $integrityConfirmedUtc.ToString("o")
        ActualRtoMinutes           = [math]::Round($actualRtoMinutes, 2)
        EndToEndRecoveryMinutes    = [math]::Round($endToEndRecoveryMinutes, 2)
        RtoTargetMinutes           = $RtoTargetMinutes
        PayloadHashMatched         = ($restoredComputedHash -eq $payloadHash)
        SourceMarkerAbsent         = (-not $sourceAfter.Item)
        ProductionOverwritten      = $false
        StorefrontBeforeHttp       = $storefrontBefore
        StorefrontAfterHttp        = $storefrontAfter
        Result                     = $resultText
    }

    Write-Step "10. FINAL RESULT"
    $result | Format-List
    Write-Utf8NoBom `
        -Path (Join-Path $evidenceDir "result.json") `
        -Content ($result | ConvertTo-Json -Depth 5)

    if (-not $rtoPassed) {
        throw "RTO FAILED: $actualRtoMinutes minutes"
    }

    $drillCompleted = $true
    Write-Host "MANDATE20_DRILL=PASS" -ForegroundColor Green
    Write-Host "DO_NOT_CLEANUP_BEFORE_MENTOR_SIGNOFF=$targetTable" -ForegroundColor Yellow
}
catch {
    Write-Host ""
    Write-Host "MANDATE20_DRILL=FAILED_OR_ABORTED" -ForegroundColor Red
    Write-Host "Error=$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "MarkerId=$markerId"
    Write-Host "TargetTable=$targetTable"
    Write-Host "MarkerInserted=$markerInserted"
    Write-Host "MarkerDeleted=$markerDeleted"
    Write-Host "RestoreRequested=$restoreRequested"
    Write-Host "EvidenceDir=$evidenceDir"
    Write-Warning "No automatic cleanup will be attempted."
    throw
}
finally {
    if ($transcriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            Write-Warning "Could not stop transcript cleanly: $($_.Exception.Message)"
        }
    }

    Write-Host ""
    Write-Host "EvidenceDir=$evidenceDir"
    if ($restoreRequested -or $drillCompleted) {
        Write-Host "Keep isolated target for mentor inspection: $targetTable" -ForegroundColor Yellow
    }
    Write-Host "This script never deletes the source table, target table, PITR, snapshots, vault, or recovery points."
}
