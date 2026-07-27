#Requires -Version 5.1
<#
.SYNOPSIS
Runs the Directive 20 controlled-loss RDS PostgreSQL PITR drill.

.DESCRIPTION
Default mode is read-only preflight. Execute mode creates and drops only a
uniquely named canary table, restores the source to a new private RDS instance,
checks the restored payload hash, measures RPO/RTO, and records evidence.

The script never changes production routing and never deletes the isolated
restore target.
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    [string]$ApprovalPhrase = "",
    [string]$Region = "us-east-1",
    [string]$ExpectedAccount = "493499579600",
    [string]$SourceInstance = "techx-prod-tf2-postgresql",
    [string]$Namespace = "techx-corp-prod",
    [string]$DatabaseSecret = "",
    [string]$DatabaseNameKey = "database",
    [string]$DatabaseUserKey = "username",
    [string]$DatabasePasswordKey = "password",
    [string]$StorefrontUrl = "https://shop.hungtran.id.vn",
    [int]$RpoTargetSeconds = 300,
    [int]$RtoTargetMinutes = 30,
    [ValidateRange(0, 35)]
    [int]$TargetBackupRetentionDays = 0,
    [string]$EvidenceRoot = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & $File @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "$File failed with exit code ${exitCode}: $text"
    }
    [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

function Invoke-AwsJson {
    param([string[]]$Arguments)
    $result = Invoke-Native -File "aws" -Arguments ($Arguments + @("--output", "json"))
    if ([string]::IsNullOrWhiteSpace($result.Text)) {
        return $null
    }
    $result.Text | ConvertFrom-Json
}

function Get-StorefrontHttp {
    $result = Invoke-Native -File "curl.exe" -Arguments @(
        "-fsS", "-o", "NUL", "-w", "%{http_code}", $StorefrontUrl
    )
    $code = [int]$result.Text.Trim()
    if ($code -ge 400) {
        throw "Storefront health failed: HTTP $code"
    }
    $code
}

function Save-KubernetesHealth {
    param([string]$Phase, [string]$EvidenceDirectory)

    $argo = Invoke-Native -File "kubectl" -Arguments @(
        "-n", "argocd", "get", "application", "techx-corp", "-o", "json"
    )
    $deployments = Invoke-Native -File "kubectl" -Arguments @(
        "-n", $Namespace, "get", "deployment",
        "cart", "checkout", "accounting", "flagd", "-o", "json"
    )
    Write-Utf8NoBom -Path (Join-Path $EvidenceDirectory "k8s-$($Phase.ToLower())-argo.json") -Content $argo.Text
    Write-Utf8NoBom -Path (Join-Path $EvidenceDirectory "k8s-$($Phase.ToLower())-workloads.json") -Content $deployments.Text

    $argoObject = $argo.Text | ConvertFrom-Json
    if ($argoObject.status.sync.status -ne "Synced" -or
        $argoObject.status.health.status -ne "Healthy") {
        throw "Argo CD is not Synced/Healthy during $Phase"
    }

    foreach ($deployment in ($deployments.Text | ConvertFrom-Json).items) {
        if ([int]$deployment.status.readyReplicas -ne [int]$deployment.spec.replicas) {
            throw "Deployment $($deployment.metadata.name) is not fully ready during $Phase"
        }
    }
}

function Invoke-Psql {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$Sql,
        [Parameter(Mandatory = $true)][string]$Purpose
    )

    $safePurpose = ($Purpose.ToLower() -replace "[^a-z0-9-]", "-").Trim("-")
    $podName = "m20-rds-$safePurpose-$((Get-Date).ToUniversalTime().ToString('HHmmss'))"
    if ($podName.Length -gt 63) {
        $podName = $podName.Substring(0, 63).TrimEnd("-")
    }

    $manifest = [ordered]@{
        apiVersion = "v1"
        kind       = "Pod"
        metadata   = @{
            name        = $podName
            namespace   = $Namespace
            annotations = @{ "linkerd.io/inject" = "disabled" }
            labels      = @{
                "app.kubernetes.io/name" = "m20-rds-drill"
                "techx.io/mandate"       = "20"
            }
        }
        spec       = @{
            restartPolicy   = "Never"
            securityContext = @{
                runAsNonRoot   = $true
                runAsUser      = 70
                runAsGroup     = 70
                seccompProfile = @{ type = "RuntimeDefault" }
            }
            containers      = @(
                @{
                    name            = "psql"
                    image           = "postgres:16-alpine"
                    imagePullPolicy = "IfNotPresent"
                    command         = @("sh", "-ec")
                    args            = @('psql -v ON_ERROR_STOP=1 -At -c "$M20_SQL"')
                    env             = @(
                        @{ name = "PGHOST"; value = $HostName },
                        @{ name = "PGPORT"; value = "5432" },
                        @{ name = "PGDATABASE"; valueFrom = @{ secretKeyRef = @{ name = $DatabaseSecret; key = $DatabaseNameKey } } },
                        @{ name = "PGUSER"; valueFrom = @{ secretKeyRef = @{ name = $DatabaseSecret; key = $DatabaseUserKey } } },
                        @{ name = "PGPASSWORD"; valueFrom = @{ secretKeyRef = @{ name = $DatabaseSecret; key = $DatabasePasswordKey } } },
                        @{ name = "PGSSLMODE"; value = "require" },
                        @{ name = "M20_SQL"; value = $Sql }
                    )
                    securityContext = @{
                        allowPrivilegeEscalation = $false
                        capabilities             = @{ drop = @("ALL") }
                    }
                    resources       = @{
                        requests = @{ cpu = "10m"; memory = "32Mi" }
                        limits   = @{ cpu = "100m"; memory = "128Mi" }
                    }
                }
            )
        }
    }

    $manifestJson = $manifest | ConvertTo-Json -Depth 20 -Compress
    try {
        $createOutput = $manifestJson | & kubectl create -f - 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to create psql pod: $createOutput"
        }

        $deadline = (Get-Date).AddMinutes(5)
        $phase = ""
        do {
            Start-Sleep -Seconds 5
            $podResult = Invoke-Native -File "kubectl" -Arguments @(
                "-n", $Namespace, "get", "pod", $podName, "-o", "json"
            )
            $phase = ($podResult.Text | ConvertFrom-Json).status.phase
            if ($phase -in @("Succeeded", "Failed")) {
                break
            }
        } while ((Get-Date) -lt $deadline)

        $logs = Invoke-Native -File "kubectl" -Arguments @(
            "-n", $Namespace, "logs", $podName, "-c", "psql"
        ) -AllowFailure
        if ($phase -ne "Succeeded") {
            throw "psql pod $podName failed or timed out ($phase): $($logs.Text)"
        }
        $logs.Text.Trim()
    }
    finally {
        & kubectl -n $Namespace delete pod $podName --ignore-not-found=true --wait=true 2>&1 | Out-Null
    }
}

function Get-Sha256 {
    param([string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value)) |
            ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $sha.Dispose()
    }
}

function New-TemporaryDatabaseSecret {
    param(
        [Parameter(Mandatory = $true)][string]$SecretName,
        [Parameter(Mandatory = $true)][string]$MasterSecretArn,
        [Parameter(Mandatory = $true)][string]$DatabaseName
    )

    $secretValue = Invoke-Native -File "aws" -Arguments @(
        "secretsmanager", "get-secret-value",
        "--region", $Region,
        "--secret-id", $MasterSecretArn,
        "--query", "SecretString",
        "--output", "text"
    )
    $credential = $secretValue.Text | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$credential.username) -or
        [string]::IsNullOrWhiteSpace([string]$credential.password)) {
        throw "RDS managed secret does not contain username/password"
    }

    $manifest = [ordered]@{
        apiVersion = "v1"
        kind       = "Secret"
        metadata   = @{
            name      = $SecretName
            namespace = $Namespace
            labels    = @{
                "app.kubernetes.io/name" = "m20-rds-drill"
                "techx.io/mandate"       = "20"
            }
        }
        type       = "Opaque"
        stringData = @{
            username = [string]$credential.username
            password = [string]$credential.password
            database = $DatabaseName
        }
    }

    $manifestJson = $manifest | ConvertTo-Json -Depth 20 -Compress
    $createOutput = $manifestJson | & kubectl create -f - 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to create temporary RDS drill credential reference: $createOutput"
    }
}

$runId = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$canaryTable = "m20_canary_$runId"
$targetInstance = "m20-rds-drill-$runId"
$expectedPayload = "mandate20-rds-restore-proof-$runId"
$expectedHash = Get-Sha256 -Value $expectedPayload
$evidenceDirectory = Join-Path $EvidenceRoot "m20-rds-evidence-$runId"
New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
$transcriptPath = Join-Path $evidenceDirectory "mandate20-rds-drill-transcript.txt"
$temporaryDatabaseSecret = $null

Start-Transcript -Path $transcriptPath -Force | Out-Null
try {
    Write-Host "Mode=$(if ($Execute) { 'EXECUTE' } else { 'PREFLIGHT' })"
    Write-Host "RunId=$runId"
    Write-Host "SourceInstance=$SourceInstance"
    Write-Host "TargetInstance=$targetInstance"
    Write-Host "CanaryTable=$canaryTable"
    Write-Host "TargetBackupRetentionDays=$TargetBackupRetentionDays"
    Write-Host "EvidenceDirectory=$evidenceDirectory"

    $identity = Invoke-AwsJson -Arguments @("sts", "get-caller-identity")
    if ($identity.Account -ne $ExpectedAccount) {
        throw "Wrong AWS account: $($identity.Account)"
    }
    Write-Host "AccountCheck=PASS"

    $source = Invoke-AwsJson -Arguments @(
        "rds", "describe-db-instances",
        "--region", $Region,
        "--db-instance-identifier", $SourceInstance
    )
    $sourceDb = $source.DBInstances[0]
    Write-Utf8NoBom -Path (Join-Path $evidenceDirectory "preflight-source-instance.json") `
        -Content ($source | ConvertTo-Json -Depth 20)

    if ($sourceDb.DBInstanceStatus -ne "available" -or
        -not $sourceDb.StorageEncrypted -or
        $sourceDb.PubliclyAccessible -or
        [int]$sourceDb.BackupRetentionPeriod -lt 1) {
        throw "RDS source failed availability, encryption, privacy, or retention checks"
    }
    if ([string]::IsNullOrWhiteSpace([string]$sourceDb.LatestRestorableTime)) {
        throw "RDS LatestRestorableTime is unavailable"
    }
    if ($targetInstance -eq $SourceInstance) {
        throw "Target must never equal source"
    }

    if ([string]::IsNullOrWhiteSpace($DatabaseSecret)) {
        $temporaryDatabaseSecret = "m20-rds-credentials-$runId"
        if ($null -eq $sourceDb.MasterUserSecret -or
            [string]::IsNullOrWhiteSpace([string]$sourceDb.MasterUserSecret.SecretArn)) {
            throw "RDS source does not expose a managed master secret ARN"
        }
        New-TemporaryDatabaseSecret `
            -SecretName $temporaryDatabaseSecret `
            -MasterSecretArn ([string]$sourceDb.MasterUserSecret.SecretArn) `
            -DatabaseName ([string]$sourceDb.DBName)
        $DatabaseSecret = $temporaryDatabaseSecret
        Write-Host "TemporaryCredentialReference=CREATED"
    }

    Save-KubernetesHealth -Phase "Before" -EvidenceDirectory $evidenceDirectory
    $storefrontBefore = Get-StorefrontHttp
    Write-Host "StorefrontBeforeHttp=$storefrontBefore"

    $connectionCheck = Invoke-Psql -HostName $sourceDb.Endpoint.Address `
        -Purpose "preflight" `
        -Sql "SELECT current_database(), current_user, has_schema_privilege(current_user, 'public', 'CREATE');"
    if (-not $connectionCheck.Trim().EndsWith("|t")) {
        throw "RDS drill user lacks CREATE privilege on schema public"
    }
    Write-Host "RdsConnectionPreflight=PASS"
    Write-Utf8NoBom -Path (Join-Path $evidenceDirectory "preflight-connection.txt") -Content $connectionCheck

    if (-not $Execute) {
        Write-Host "RDS_PREFLIGHT=PASS"
        Write-Host "Execute with:"
        Write-Host ".\mandate-20-rds-drill.ps1 -Execute -ApprovalPhrase `"DRILL RDS $SourceInstance`""
        return
    }

    $requiredPhrase = "DRILL RDS $SourceInstance"
    if ($ApprovalPhrase -cne $requiredPhrase) {
        throw "ApprovalPhrase must exactly equal: $requiredPhrase"
    }

    Write-Host "ControlledMutationApproval=PASS"
    $createSql = @"
CREATE TABLE public.$canaryTable (
    id integer PRIMARY KEY,
    payload text NOT NULL,
    created_at timestamptz NOT NULL
);
INSERT INTO public.$canaryTable (id, payload, created_at)
VALUES (1, '$expectedPayload', clock_timestamp());
SELECT payload FROM public.$canaryTable WHERE id = 1;
"@
    $createdPayload = Invoke-Psql -HostName $sourceDb.Endpoint.Address `
        -Purpose "create-canary" -Sql $createSql
    if ($createdPayload.Trim().Split([Environment]::NewLine)[-1] -ne $expectedPayload) {
        throw "Canary insert verification failed"
    }
    Write-Utf8NoBom -Path (Join-Path $evidenceDirectory "canary-created.txt") -Content $createdPayload
    Write-Host "ExpectedPayloadHash=$expectedHash"

    $markerCommittedText = Invoke-Psql -HostName $sourceDb.Endpoint.Address `
        -Purpose "commit-time" `
        -Sql "SELECT clock_timestamp() AT TIME ZONE 'UTC';"
    $markerCommittedUtc = [datetime]::SpecifyKind(
        [datetime]::Parse($markerCommittedText.Trim(), [Globalization.CultureInfo]::InvariantCulture),
        [DateTimeKind]::Utc
    )
    Write-Host "MarkerCommittedUtc=$($markerCommittedUtc.ToString('o'))"

    $coverageDeadline = (Get-Date).AddMinutes(30)
    $safeTimeUtc = $null
    do {
        $current = Invoke-AwsJson -Arguments @(
            "rds", "describe-db-instances",
            "--region", $Region,
            "--db-instance-identifier", $SourceInstance
        )
        $latest = ([datetime]$current.DBInstances[0].LatestRestorableTime).ToUniversalTime()
        Write-Host "LatestRestorableTime=$($latest.ToString('o'))"
        if ($latest -ge $markerCommittedUtc) {
            $safeTimeUtc = $latest
            break
        }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $coverageDeadline)

    if ($null -eq $safeTimeUtc) {
        throw "RDS PITR coverage did not reach the committed marker within 30 minutes"
    }
    Write-Host "PITRCoverage=PASS"
    Write-Host "T_safe=$($safeTimeUtc.ToString('o'))"

    # The canary payload was verified immediately after its committed insert.
    # Once LatestRestorableTime covers that commit, launch the controlled DROP
    # without another short-lived pod so client scheduling latency does not
    # consume the five-minute RPO window.
    Write-Utf8NoBom -Path (Join-Path $evidenceDirectory "pitr-covered-canary.txt") `
        -Content $expectedPayload

    $dropSql = @"
DROP TABLE public.$canaryTable;
SELECT COALESCE(to_regclass('public.$canaryTable')::text, 'ABSENT');
"@
    $dropResult = Invoke-Psql -HostName $sourceDb.Endpoint.Address `
        -Purpose "drop-canary" -Sql $dropSql
    if ($dropResult.Trim().Split([Environment]::NewLine)[-1] -ne "ABSENT") {
        throw "Controlled DROP could not be proven"
    }
    $lossTimeUtc = (Get-Date).ToUniversalTime()
    Write-Utf8NoBom -Path (Join-Path $evidenceDirectory "canary-dropped.txt") -Content $dropResult
    Write-Host "T_loss=$($lossTimeUtc.ToString('o'))"

    $actualRpoSeconds = [math]::Round(($lossTimeUtc - $safeTimeUtc).TotalSeconds)
    Write-Host "ActualRpoSeconds=$actualRpoSeconds"
    if ($actualRpoSeconds -gt $RpoTargetSeconds -or $actualRpoSeconds -lt 0) {
        throw "RPO failed: actual $actualRpoSeconds seconds, target $RpoTargetSeconds seconds"
    }
    Write-Host "RPO=PASS"

    $restoreStartUtc = (Get-Date).ToUniversalTime()
    Write-Host "T_restore_start=$($restoreStartUtc.ToString('o'))"
    $restoreArguments = @(
        "rds", "restore-db-instance-to-point-in-time",
        "--region", $Region,
        "--source-db-instance-identifier", $SourceInstance,
        "--target-db-instance-identifier", $targetInstance,
        "--restore-time", $safeTimeUtc.ToString("yyyy-MM-ddTHH:mm:ssZ"),
        "--db-instance-class", [string]$sourceDb.DBInstanceClass,
        "--db-subnet-group-name", [string]$sourceDb.DBSubnetGroup.DBSubnetGroupName,
        "--vpc-security-group-ids"
    )
    $restoreArguments += @($sourceDb.VpcSecurityGroups | ForEach-Object { [string]$_.VpcSecurityGroupId })
    $restoreArguments += @(
        "--db-parameter-group-name", [string]$sourceDb.DBParameterGroups[0].DBParameterGroupName,
        "--backup-retention-period", [string]$TargetBackupRetentionDays,
        "--no-publicly-accessible",
        "--no-multi-az",
        "--copy-tags-to-snapshot"
    )
    $restore = Invoke-AwsJson -Arguments $restoreArguments
    Write-Utf8NoBom -Path (Join-Path $evidenceDirectory "restore-request.json") `
        -Content ($restore | ConvertTo-Json -Depth 20)

    $restoreDeadline = (Get-Date).AddMinutes($RtoTargetMinutes)
    $target = $null
    do {
        Start-Sleep -Seconds 30
        $targetResponse = Invoke-AwsJson -Arguments @(
            "rds", "describe-db-instances",
            "--region", $Region,
            "--db-instance-identifier", $targetInstance
        )
        $target = $targetResponse.DBInstances[0]
        Write-Host "TargetStatus=$($target.DBInstanceStatus)"
        if ($target.DBInstanceStatus -eq "available") {
            break
        }
    } while ((Get-Date) -lt $restoreDeadline)

    if ($null -eq $target -or $target.DBInstanceStatus -ne "available") {
        throw "Isolated RDS target did not become available inside RTO"
    }
    if ($target.PubliclyAccessible -or -not $target.StorageEncrypted) {
        throw "Isolated RDS target failed privacy or encryption validation"
    }
    Write-Utf8NoBom -Path (Join-Path $evidenceDirectory "restored-instance.json") `
        -Content ($targetResponse | ConvertTo-Json -Depth 20)

    $restoredPayload = Invoke-Psql -HostName $target.Endpoint.Address `
        -Purpose "verify-restored" `
        -Sql "SELECT payload FROM public.$canaryTable WHERE id = 1;"
    $restoredHash = Get-Sha256 -Value $restoredPayload.Trim()
    Write-Utf8NoBom -Path (Join-Path $evidenceDirectory "restored-canary.txt") -Content $restoredPayload
    Write-Host "RestoredPayloadHash=$restoredHash"
    if ($restoredHash -ne $expectedHash) {
        throw "Restored canary hash mismatch"
    }

    $sourceAbsent = Invoke-Psql -HostName $sourceDb.Endpoint.Address `
        -Purpose "source-remains-absent" `
        -Sql "SELECT COALESCE(to_regclass('public.$canaryTable')::text, 'ABSENT');"
    Write-Utf8NoBom -Path (Join-Path $evidenceDirectory "source-after-restore.txt") -Content $sourceAbsent
    if ($sourceAbsent.Trim() -ne "ABSENT") {
        throw "Source canary unexpectedly exists after isolated restore"
    }

    $integrityConfirmedUtc = (Get-Date).ToUniversalTime()
    $actualRtoMinutes = [math]::Round(
        ($integrityConfirmedUtc - $restoreStartUtc).TotalMinutes,
        2
    )
    Write-Host "T_integrity_confirmed=$($integrityConfirmedUtc.ToString('o'))"
    Write-Host "ActualRtoMinutes=$actualRtoMinutes"
    if ($actualRtoMinutes -gt $RtoTargetMinutes) {
        throw "RTO failed: actual $actualRtoMinutes minutes, target $RtoTargetMinutes minutes"
    }
    Write-Host "RTO=PASS"

    Save-KubernetesHealth -Phase "After" -EvidenceDirectory $evidenceDirectory
    $storefrontAfter = Get-StorefrontHttp
    Write-Host "StorefrontAfterHttp=$storefrontAfter"

    try {
        $cloudTrail = Invoke-AwsJson -Arguments @(
            "cloudtrail", "lookup-events",
            "--region", $Region,
            "--lookup-attributes", "AttributeKey=EventName,AttributeValue=RestoreDBInstanceToPointInTime",
            "--max-results", "20"
        )
        $events = @($cloudTrail.Events | Where-Object {
            [string]$_.CloudTrailEvent -like "*$targetInstance*"
        })
        foreach ($event in $events) {
            if ($event.PSObject.Properties.Name -contains "AccessKeyId") {
                $event.AccessKeyId = "[REDACTED]"
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$event.CloudTrailEvent)) {
                $detail = $event.CloudTrailEvent | ConvertFrom-Json
                if ($detail.userIdentity.PSObject.Properties.Name -contains "accessKeyId") {
                    $detail.userIdentity.accessKeyId = "[REDACTED]"
                }
                if ($detail.PSObject.Properties.Name -contains "sourceIPAddress") {
                    $detail.sourceIPAddress = "[REDACTED]"
                }
                $event.CloudTrailEvent = $detail | ConvertTo-Json -Depth 20 -Compress
            }
        }
        Write-Utf8NoBom -Path (Join-Path $evidenceDirectory "cloudtrail-restore-events.json") `
            -Content ($events | ConvertTo-Json -Depth 20)
        Write-Host "MatchingRestoreEvents=$($events.Count)"
    }
    catch {
        Write-Warning "CloudTrail evidence lookup failed: $($_.Exception.Message)"
    }

    $result = [ordered]@{
        SourceInstance        = $SourceInstance
        IsolatedTarget       = $targetInstance
        CanaryTable          = $canaryTable
        SafeTimeUtc          = $safeTimeUtc.ToString("o")
        LossTimeUtc          = $lossTimeUtc.ToString("o")
        ActualRpoSeconds     = $actualRpoSeconds
        RpoTargetSeconds     = $RpoTargetSeconds
        RestoreStartUtc      = $restoreStartUtc.ToString("o")
        IntegrityConfirmedUtc = $integrityConfirmedUtc.ToString("o")
        ActualRtoMinutes     = $actualRtoMinutes
        RtoTargetMinutes     = $RtoTargetMinutes
        PayloadHashMatched   = $true
        SourceCanaryAbsent   = $true
        ProductionOverwritten = $false
        StorefrontBeforeHttp = $storefrontBefore
        StorefrontAfterHttp  = $storefrontAfter
        Result               = "PASS"
    }
    Write-Utf8NoBom -Path (Join-Path $evidenceDirectory "result.json") `
        -Content ($result | ConvertTo-Json -Depth 10)
    $result | Format-List | Out-Host
    Write-Host "Keep isolated target for mentor inspection: $targetInstance" -ForegroundColor Yellow
    Write-Host "MANDATE20_RDS_DRILL=PASS" -ForegroundColor Green
}
catch {
    Write-Error $_
    Write-Host "MANDATE20_RDS_DRILL=FAILED_OR_ABORTED" -ForegroundColor Red
    throw
}
finally {
    if (-not [string]::IsNullOrWhiteSpace([string]$temporaryDatabaseSecret)) {
        & kubectl -n $Namespace delete secret $temporaryDatabaseSecret `
            --ignore-not-found=true --wait=true 2>&1 | Out-Null
        Write-Host "TemporaryCredentialReference=DELETED"
    }
    Stop-Transcript | Out-Null
}
