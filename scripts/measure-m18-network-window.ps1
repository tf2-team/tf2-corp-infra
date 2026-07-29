# Measure Mandate 18 live network usage for one bounded load-test window.
# Requires AWS CLI in WSL and an ACTIVE VPC Flow Log with flow-direction + az-id.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [datetime]$StartUtc,

  [Parameter(Mandatory = $true)]
  [datetime]$EndUtc,

  [string]$Region = "us-east-1",
  [string]$VpcId = "vpc-0eef6ab7c99ef3bf4",
  [string]$FlowLogGroup = "/aws/vpc/techx-prod-tf2-vpc/flow-logs",

  # Published us-east-1 on-demand rates. They are explicit inputs so a future
  # rate change is reviewed instead of silently changing the comparison.
  [decimal]$NatGatewayHourUsd = 0.045,
  [decimal]$NatGatewayDataGbUsd = 0.045,
  [decimal]$CrossAzGbUsd = 0.020,
  [decimal]$Gp3GbMonthUsd = 0.080,
  [decimal]$SnapshotGbMonthUsd = 0.050,
  [decimal]$InterfaceEndpointHourUsd = 0.010,
  [decimal]$InterfaceEndpointDataGbUsd = 0.010,

  # Disabled by default: publishing is an explicit, user-authorised action.
  # When enabled, the calculated evidence is written to TechX/Mandate18 so
  # Grafana can show the exact controlled window without relying on CUR delay.
  [switch]$PublishCloudWatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-AwsJson {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
  $raw = & wsl.exe aws @Arguments --output json 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "AWS CLI command failed: aws $($Arguments -join ' ')`n$($raw -join "`n")"
  }
  return ($raw -join "`n") | ConvertFrom-Json
}

function Get-NatMetricSum {
  param([string]$NatGatewayId, [string]$MetricName)
  $response = Invoke-AwsJson cloudwatch get-metric-statistics `
    --region $Region `
    --namespace AWS/NATGateway `
    --metric-name $MetricName `
    --dimensions "Name=NatGatewayId,Value=$NatGatewayId" `
    --statistics Sum `
    --period 60 `
    --start-time $StartUtc.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") `
    --end-time $EndUtc.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  if ($null -eq $response.Datapoints -or $response.Datapoints.Count -eq 0) {
    return 0
  }
  return [double](($response.Datapoints | Measure-Object -Property Sum -Sum).Sum)
}

$start = $StartUtc.ToUniversalTime()
$end = $EndUtc.ToUniversalTime()
if ($end -le $start) { throw "EndUtc must be later than StartUtc." }
if ($end -gt [datetime]::UtcNow) { throw "EndUtc is in the future. Use the UTC start and end of a completed load-test window." }

$startEpoch = [DateTimeOffset]::new($start).ToUnixTimeSeconds()
$endEpoch = [DateTimeOffset]::new($end).ToUnixTimeSeconds()

# The Flow Log format is defined in modules/vpc/main.tf:
# version account interface src dst srcPort dstPort protocol packets bytes start end action status azId direction
$query = @'
fields @message
| parse @message "* * * * * * * * * * * * * * * *" as version, accountId, interfaceId, srcAddr, dstAddr, srcPort, dstPort, protocol, packets, flowBytes, start, end, action, logStatus, sourceAzId, direction
| filter action = "ACCEPT" and direction = "egress" and logStatus = "OK"
| stats sum(flowBytes) as totalBytes by interfaceId, dstAddr, sourceAzId
'@

$queryStart = Invoke-AwsJson logs start-query `
  --region $Region `
  --log-group-name $FlowLogGroup `
  --start-time $startEpoch `
  --end-time $endEpoch `
  --query-string $query

$queryResult = $null
for ($attempt = 0; $attempt -lt 30; $attempt++) {
  Start-Sleep -Seconds 2
  $queryResult = Invoke-AwsJson logs get-query-results --region $Region --query-id $queryStart.queryId
  if ($queryResult.status -in @("Complete", "Failed", "Cancelled", "Timeout")) { break }
}
if ($queryResult.status -ne "Complete") { throw "Logs Insights query did not complete: $($queryResult.status)" }

$destinationAzCache = @{}
$interfaces = Invoke-AwsJson ec2 describe-network-interfaces `
  --region $Region `
  --filters "Name=vpc-id,Values=$VpcId"
foreach ($interface in $interfaces.NetworkInterfaces) {
  foreach ($address in $interface.PrivateIpAddresses) {
    $destinationAzCache[$address.PrivateIpAddress] = $interface.AvailabilityZoneId
  }
}

function Publish-M18Evidence {
  param([array]$MetricData)
  if (-not $PublishCloudWatch) { return }

  $payload = $MetricData | ConvertTo-Json -Compress -Depth 6
  Invoke-AwsJson cloudwatch put-metric-data `
    --region $Region `
    --namespace TechX/Mandate18 `
    --metric-data $payload | Out-Null
}

$crossAzPairs = @{}
foreach ($result in $queryResult.results) {
  $fields = @{}
  foreach ($field in $result) { $fields[$field.field] = $field.value }
  $destinationIp = $fields.dstAddr
  if ([string]::IsNullOrWhiteSpace($destinationIp) -or $destinationIp -eq "-") { continue }

  $sourceAz = $fields.sourceAzId
  $destinationAz = if ($destinationAzCache.ContainsKey($destinationIp)) {
    $destinationAzCache[$destinationIp]
  } else {
    $null
  }
  if ($null -eq $destinationAz -or $sourceAz -eq $destinationAz) { continue }
  $pair = "$sourceAz -> $destinationAz"
  $crossAzPairs[$pair] = ($crossAzPairs[$pair] ?? 0) + [double]$fields.totalBytes
}

$nats = Invoke-AwsJson ec2 describe-nat-gateways --region $Region --filter "Name=vpc-id,Values=$VpcId" "Name=state,Values=available"
$natUsage = foreach ($nat in $nats.NatGateways) {
  $toDestination = Get-NatMetricSum -NatGatewayId $nat.NatGatewayId -MetricName "BytesOutToDestination"
  $toSource = Get-NatMetricSum -NatGatewayId $nat.NatGatewayId -MetricName "BytesOutToSource"
  [PSCustomObject]@{
    Driver                        = "NAT data processing"
    NatGatewayId                  = $nat.NatGatewayId
    BytesOutToDestinationGiB      = [math]::Round($toDestination / 1GB, 4)
    BytesOutToSourceGiB           = [math]::Round($toSource / 1GB, 4)
    TotalDataProcessedGiB         = [math]::Round(($toDestination + $toSource) / 1GB, 4)
  }
}

$crossAzUsage = foreach ($pair in $crossAzPairs.GetEnumerator() | Sort-Object Value -Descending) {
  [PSCustomObject]@{
    Driver       = "Cross-AZ data transfer"
    Resource     = $pair.Key
    TotalGiB     = [math]::Round($pair.Value / 1GB, 4)
  }
}

$totalCrossAzGiB = [math]::Round((($crossAzUsage | Measure-Object -Property TotalGiB -Sum).Sum), 4)
$totalCrossAzBytes = [double](($crossAzPairs.Values | Measure-Object -Sum).Sum)

# Storage is an allocated-capacity driver, not traffic generated in the 15-minute
# window. Keep its unit separate from transfer GiB rather than inventing a rank.
$volumes = Invoke-AwsJson ec2 describe-volumes --region $Region
$totalEbsGiB = [math]::Round((($volumes.Volumes | Measure-Object -Property Size -Sum).Sum), 2)

# The current VPC has only an S3 Gateway Endpoint. Gateway Endpoints have no
# endpoint-hour or data-processing charge. Interface Endpoint rows therefore
# intentionally report zero until an Interface Endpoint exists.
$availableEndpoints = @((Invoke-AwsJson ec2 describe-vpc-endpoints --region $Region --filters "Name=vpc-id,Values=$VpcId").VpcEndpoints | Where-Object State -eq "available")
$interfaceEndpointCount = @($availableEndpoints | Where-Object VpcEndpointType -eq "Interface").Count

# List price is used solely to normalize heterogeneous AWS usage units. The
# account's billed cost is credit-masked, so this is not an invoice amount.
$windowHours = [decimal](($end - $start).TotalHours)
$natGatewayHours = [decimal]$nats.NatGateways.Count * $windowHours
$totalNatDataProcessedBytes = [double](($natUsage | ForEach-Object { $_.TotalDataProcessedGiB * 1GB } | Measure-Object -Sum).Sum)
$totalNatDataProcessedGB = [decimal]($totalNatDataProcessedBytes / 1e9)
$totalCrossAzGB = [decimal]($totalCrossAzBytes / 1e9)
$ebsWindowGbMonth = [decimal]$totalEbsGiB * $windowHours / [decimal]730
$interfaceEndpointHours = [decimal]$interfaceEndpointCount * $windowHours
$interfaceEndpointDataGB = [decimal]0

# Snapshot usage is a GB-month quantity, not a snapshot count. Cost Explorer
# publishes it at billing cadence, so use the month-to-date value to estimate
# its storage footprint, then prorate that footprint to this same test window.
$billingMonthStart = [datetime]::new($end.Year, $end.Month, 1, 0, 0, 0, [DateTimeKind]::Utc)
$billingUsageEnd = $end.Date.AddDays(1)
$snapshotFilter = '{"Dimensions":{"Key":"USAGE_TYPE","Values":["EBS:SnapshotUsage"]}}'
$snapshotUsageResult = Invoke-AwsJson ce get-cost-and-usage `
  --region $Region `
  --time-period "Start=$($billingMonthStart.ToString('yyyy-MM-dd')),End=$($billingUsageEnd.ToString('yyyy-MM-dd'))" `
  --granularity MONTHLY `
  --metrics UsageQuantity `
  --filter $snapshotFilter
$snapshotGbMonthMtd = [decimal]$snapshotUsageResult.ResultsByTime[0].Total.UsageQuantity.Amount
$billingHoursCovered = [decimal](($billingUsageEnd - $billingMonthStart).TotalHours)
$snapshotStoredGB = if ($billingHoursCovered -gt 0) { $snapshotGbMonthMtd * [decimal]730 / $billingHoursCovered } else { [decimal]0 }
$snapshotWindowGbMonth = $snapshotStoredGB * $windowHours / [decimal]730

$costDrivers = @(
  [PSCustomObject]@{ Driver = "NAT Gateway active time"; Usage = [math]::Round($natGatewayHours, 4); Unit = "gateway-hours"; RateUsd = $NatGatewayHourUsd; EstimatedUsd = [math]::Round($natGatewayHours * $NatGatewayHourUsd, 6) }
  [PSCustomObject]@{ Driver = "NAT Gateway data processed"; Usage = [math]::Round($totalNatDataProcessedGB, 6); Unit = "GB"; RateUsd = $NatGatewayDataGbUsd; EstimatedUsd = [math]::Round($totalNatDataProcessedGB * $NatGatewayDataGbUsd, 6) }
  [PSCustomObject]@{ Driver = "Cross-AZ data transfer"; Usage = [math]::Round($totalCrossAzGB, 6); Unit = "GB"; RateUsd = $CrossAzGbUsd; EstimatedUsd = [math]::Round($totalCrossAzGB * $CrossAzGbUsd, 6) }
  [PSCustomObject]@{ Driver = "EBS gp3 storage"; Usage = [math]::Round($ebsWindowGbMonth, 6); Unit = "GB-month (window share)"; RateUsd = $Gp3GbMonthUsd; EstimatedUsd = [math]::Round($ebsWindowGbMonth * $Gp3GbMonthUsd, 6) }
  [PSCustomObject]@{ Driver = "EBS snapshot storage"; Usage = [math]::Round($snapshotWindowGbMonth, 6); Unit = "GB-month (window share)"; RateUsd = $SnapshotGbMonthUsd; EstimatedUsd = [math]::Round($snapshotWindowGbMonth * $SnapshotGbMonthUsd, 6) }
  [PSCustomObject]@{ Driver = "VPC Interface Endpoint active time"; Usage = [math]::Round($interfaceEndpointHours, 4); Unit = "endpoint-hours"; RateUsd = $InterfaceEndpointHourUsd; EstimatedUsd = [math]::Round($interfaceEndpointHours * $InterfaceEndpointHourUsd, 6) }
  [PSCustomObject]@{ Driver = "VPC Interface Endpoint data processed"; Usage = $interfaceEndpointDataGB; Unit = "GB"; RateUsd = $InterfaceEndpointDataGbUsd; EstimatedUsd = 0 }
) | Sort-Object EstimatedUsd -Descending
$totalEstimatedUsd = [math]::Round((($costDrivers | Measure-Object -Property EstimatedUsd -Sum).Sum), 6)

$evidenceMetrics = @()
foreach ($nat in $natUsage) {
  $evidenceMetrics += @{
    MetricName = "NatDataProcessedBytes"; Value = [double]($nat.TotalDataProcessedGiB * 1GB); Unit = "Bytes"
    Dimensions = @(@{ Name = "NatGatewayId"; Value = $nat.NatGatewayId })
  }
}
$evidenceMetrics += @{ MetricName = "NatDataProcessedBytesTotal"; Value = $totalNatDataProcessedBytes; Unit = "Bytes" }
foreach ($pair in $crossAzPairs.GetEnumerator()) {
  $az = $pair.Key -split " -> "
  $evidenceMetrics += @{
    MetricName = "CrossAzDataTransferBytes"; Value = [double]$pair.Value; Unit = "Bytes"
    Dimensions = @(@{ Name = "SourceAz"; Value = $az[0] }, @{ Name = "DestinationAz"; Value = $az[1] })
  }
}
$evidenceMetrics += @(
  @{ MetricName = "CrossAzDataTransferBytesTotal"; Value = $totalCrossAzBytes; Unit = "Bytes" },
  @{ MetricName = "NatGatewayActiveHours"; Value = [double]$natGatewayHours; Unit = "Count" },
  @{ MetricName = "EbsGp3AllocatedGiB"; Value = [double]$totalEbsGiB; Unit = "Gigabytes" },
  @{ MetricName = "EbsSnapshotStoredGB"; Value = [double]$snapshotStoredGB; Unit = "Gigabytes" },
  @{ MetricName = "InterfaceEndpointActiveHours"; Value = [double]$interfaceEndpointHours; Unit = "Count" },
  @{ MetricName = "InterfaceEndpointDataProcessedBytes"; Value = 0; Unit = "Bytes" },
  @{ MetricName = "EstimatedNonComputeCostUsdTotal"; Value = [double]$totalEstimatedUsd; Unit = "None" }
)
foreach ($driver in $costDrivers) {
  $evidenceMetrics += @{
    MetricName = "EstimatedNonComputeCostUsd"; Value = [double]$driver.EstimatedUsd; Unit = "None"
    Dimensions = @(@{ Name = "Driver"; Value = $driver.Driver })
  }
}
Publish-M18Evidence -MetricData $evidenceMetrics

Write-Host "`nMandate 18 live network usage: $($start.ToString('u')) to $($end.ToString('u'))" -ForegroundColor Cyan
Write-Host "`nNAT data processing" -ForegroundColor Cyan
Write-Host "CloudWatch metrics: BytesOutToDestination + BytesOutToSource = TotalDataProcessed" -ForegroundColor DarkCyan
$natUsage | Format-Table -AutoSize
$totalNatDataProcessedGiB = [math]::Round((($natUsage | Measure-Object -Property TotalDataProcessedGiB -Sum).Sum), 4)
Write-Host "Total NAT data processing (all NAT Gateways): $totalNatDataProcessedGiB GiB" -ForegroundColor Cyan
Write-Host "`nCross-AZ data transfer" -ForegroundColor Cyan
if ($crossAzUsage) {
  $crossAzUsage | Format-Table -AutoSize
  Write-Host "Total Cross-AZ data transfer: $totalCrossAzGiB GiB" -ForegroundColor Cyan
} else {
  Write-Host "No cross-AZ flow records found in this window."
}

Write-Host "`nTop non-compute cost drivers (list-price equivalent)" -ForegroundColor Cyan
$costDrivers |
  Select-Object Driver, Usage, Unit, @{ Name = "ListPriceUsdPerUnit"; Expression = { '$' + ([decimal]$_.RateUsd).ToString('F3') } }, @{ Name = "EstimatedUsd"; Expression = { '$' + ([decimal]$_.EstimatedUsd).ToString('F6') } } |
  Format-Table -AutoSize
Write-Host "Total estimated non-compute cost for this window: `$$totalEstimatedUsd" -ForegroundColor Cyan
Write-Host "Snapshot storage is prorated from Cost Explorer month-to-date SnapshotUsage: $snapshotGbMonthMtd GB-month." -ForegroundColor DarkCyan
if ($PublishCloudWatch) {
  Write-Host "Published Mandate 18 evidence to CloudWatch namespace TechX/Mandate18." -ForegroundColor Cyan
} else {
  Write-Host "Not published. Re-run with -PublishCloudWatch to populate the Grafana live-evidence panels." -ForegroundColor DarkYellow
}
