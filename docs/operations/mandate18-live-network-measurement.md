# Mandate 18: live 15-minute network measurement

Cost Explorer is daily billing data and is not used to compare a short load test.
VPC Flow Logs are enabled only for a bounded investigation and aggregate at one
minute. The measurement script calculates NAT bytes from CloudWatch and
Cross-AZ bytes by mapping each egress Flow Log destination IP to its ENI AZ.

Run the same load profile for a known 15-minute UTC window. Wait several minutes
after it ends for Flow Logs delivery, then run:

```powershell
./scripts/measure-m18-network-window.ps1 `
  -StartUtc '2026-07-29T10:00:00Z' `
  -EndUtc '2026-07-29T10:15:00Z'
```

Record the terminal table before and after the endpoint change. NAT data
processing and Cross-AZ bytes are compared only between equal load windows.
When the bounded investigation is complete, set `vpc_flow_logs_enabled = false`
or restore the longer aggregation interval to limit CloudWatch Logs ingestion.
