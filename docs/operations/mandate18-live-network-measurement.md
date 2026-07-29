# Mandate 18: live 15-minute network measurement

Cost Explorer is daily billing data and is not used to compare a short load test.
VPC Flow Logs are enabled only for a bounded investigation and aggregate at one
minute. The measurement script calculates NAT bytes from CloudWatch and
Cross-AZ bytes by mapping each egress Flow Log destination IP to its ENI AZ.

For each NAT Gateway, `TotalDataProcessedGiB` is the sum of the two
`AWS/NATGateway` metrics `BytesOutToDestination` and `BytesOutToSource` in the
selected window. The script does not sum all four NAT byte metrics because that
would count each flow twice.

Run the same load profile for a known 15-minute UTC window. Wait several minutes
after it ends for Flow Logs delivery, then run:

```powershell
./scripts/measure-m18-network-window.ps1 `
  -StartUtc '<load-test-start-in-UTC>' `
  -EndUtc '<load-test-end-in-UTC>'
```

For example, a load test from 18:00 to 18:15 in Vietnam (UTC+7) uses
`11:00:00Z` and `11:15:00Z`. Both timestamps must be in the past; wait several
minutes after the test before running the script so Flow Logs have arrived.

Record the terminal table before and after the endpoint change. NAT data
processing and Cross-AZ bytes are compared only between equal load windows.

The final table converts every driver to an estimated us-east-1 list-price cost
for the same window, so that unlike raw GB, GB-month and endpoint-hour usage it
can be ranked and totalled. It lists NAT active time, NAT data processing,
Cross-AZ transfer, EBS gp3 storage, EBS snapshot storage, Interface Endpoint
active time and Interface Endpoint data processing. The values are a normalized
comparison, not the account invoice: credits mask billed cost.

The current VPC has only an S3 Gateway Endpoint. It has no endpoint-hour or
data-processing charge, so both Interface Endpoint rows correctly show zero.
The snapshot row comes from Cost Explorer `EBS:SnapshotUsage` in GB-month. The
script derives the current stored footprint from the month-to-date amount and
prorates it to the selected test window; it never substitutes a recovery-point
count for storage usage.
When the bounded investigation is complete, set `vpc_flow_logs_enabled = false`
or restore the longer aggregation interval to limit CloudWatch Logs ingestion.
