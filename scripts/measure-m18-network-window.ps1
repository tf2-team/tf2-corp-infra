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
  [string]$FlowLogGroup = "/aws/vpc/techx-prod-tf2-vpc/flow-logs"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-AwsJson {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
  $raw = & wsl.exe aws @Arguments --output json
  if ($LASTEXITCODE -ne 0) { throw "AWS CLI command failed: aws $($Arguments -join ' ')" }
  return $raw | ConvertFrom-Json
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
  return [double](($response.Datapoints | Measure-Object -Property Sum -Sum).Sum)
}

$start = $StartUtc.ToUniversalTime()
$end = $EndUtc.ToUniversalTime()
if ($end -le $start) { throw "EndUtc must be later than StartUtc." }

$startEpoch = [DateTimeOffset]::new($start).ToUnixTimeSeconds()
$endEpoch = [DateTimeOffset]::new($end).ToUnixTimeSeconds()

# The Flow Log format is defined in modules/vpc/main.tf:
# version account interface src dst srcPort dstPort protocol packets bytes start end action status azId direction
$query = @'
fields @message
| parse @message "* * * * * * * * * * * * * * * *" as version, accountId, interfaceId, srcAddr, dstAddr, srcPort, dstPort, protocol, packets, bytes, start, end, action, logStatus, sourceAzId, direction
| filter action = "ACCEPT" and direction = "egress" and logStatus = "OK"
| stats sum(bytes) as bytes by interfaceId, dstAddr, sourceAzId
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
$crossAzPairs = @{}
foreach ($result in $queryResult.results) {
  $fields = @{}
  foreach ($field in $result) { $fields[$field.field] = $field.value }
  $destinationIp = $fields.dstAddr
  if ([string]::IsNullOrWhiteSpace($destinationIp) -or $destinationIp -eq "-") { continue }

  if (-not $destinationAzCache.ContainsKey($destinationIp)) {
    $eni = Invoke-AwsJson ec2 describe-network-interfaces `
      --region $Region `
      --filters "Name=addresses.private-ip-address,Values=$destinationIp"
    $destinationAzCache[$destinationIp] = if ($eni.NetworkInterfaces.Count -gt 0) {
      $eni.NetworkInterfaces[0].AvailabilityZoneId
    } else {
      $null
    }
  }

  $sourceAz = $fields.sourceAzId
  $destinationAz = $destinationAzCache[$destinationIp]
  if ($null -eq $destinationAz -or $sourceAz -eq $destinationAz) { continue }
  $pair = "$sourceAz -> $destinationAz"
  $crossAzPairs[$pair] = ($crossAzPairs[$pair] ?? 0) + [double]$fields.bytes
}

$nats = Invoke-AwsJson ec2 describe-nat-gateways --region $Region --filter "Name=vpc-id,Values=$VpcId" "Name=state,Values=available"
$natUsage = foreach ($nat in $nats.NatGateways) {
  $toDestination = Get-NatMetricSum -NatGatewayId $nat.NatGatewayId -MetricName "BytesOutToDestination"
  $toSource = Get-NatMetricSum -NatGatewayId $nat.NatGatewayId -MetricName "BytesOutToSource"
  [PSCustomObject]@{
    Driver             = "NAT data processing"
    Resource           = $nat.NatGatewayId
    ToDestinationGiB   = [math]::Round($toDestination / 1GB, 4)
    ToSourceGiB        = [math]::Round($toSource / 1GB, 4)
    TotalGiB           = [math]::Round(($toDestination + $toSource) / 1GB, 4)
  }
}

$crossAzUsage = foreach ($pair in $crossAzPairs.GetEnumerator() | Sort-Object Value -Descending) {
  [PSCustomObject]@{
    Driver       = "Cross-AZ data transfer"
    Resource     = $pair.Key
    TotalGiB     = [math]::Round($pair.Value / 1GB, 4)
  }
}

Write-Host "`nMandate 18 live network usage: $($start.ToString('u')) to $($end.ToString('u'))" -ForegroundColor Cyan
Write-Host "`nNAT data processing" -ForegroundColor Cyan
$natUsage | Format-Table -AutoSize
Write-Host "`nCross-AZ data transfer" -ForegroundColor Cyan
if ($crossAzUsage) {
  $crossAzUsage | Format-Table -AutoSize
} else {
  Write-Host "No cross-AZ flow records found in this window."
}

$topUsage = @(
  $natUsage | ForEach-Object {
    [PSCustomObject]@{ Driver = "NAT data processing"; Resource = $_.Resource; UsageGiB = $_.TotalGiB }
  }
  $crossAzUsage | ForEach-Object {
    [PSCustomObject]@{ Driver = "Cross-AZ data transfer"; Resource = $_.Resource; UsageGiB = $_.TotalGiB }
  }
) | Sort-Object UsageGiB -Descending
Write-Host "`nTop live data-transfer usage drivers" -ForegroundColor Cyan
$topUsage | Format-Table -AutoSize
