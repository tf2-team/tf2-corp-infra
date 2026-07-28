# Mandate 18 — live usage evidence

CUR/Athena is retained for historical billing reconciliation. It is not the
source used to demonstrate a change immediately after it is deployed.

## NAT and telemetry

Open **Directive 18 — Live Usage Evidence** in Grafana. Its NAT chart reads
one-minute `AWS/NATGateway` CloudWatch metrics directly; the telemetry chart
reads the OpenTelemetry Collector counters from Prometheus. Compare equal
controlled windows before and after a route or endpoint change.

## Optional VPC Flow Logs

Flow Logs are disabled in normal operation. They add CloudWatch Logs ingest
cost and are enabled only when a Cross-AZ traffic pair must be investigated.

```hcl
vpc_flow_logs_enabled           = true
vpc_flow_logs_retention_in_days = 7
```

Apply the approved infrastructure change, wait for records to arrive, inspect
`/aws/vpc/techx-prod-tf2-vpc/flow-logs` in CloudWatch Logs Insights, and map
the observed interfaces/source-destination addresses to their ENI/subnet AZs.
Return `vpc_flow_logs_enabled` to `false` after recording the evidence. The
log group, delivery role and Flow Log are then removed by Terraform.

The Flow Log record includes interface ID, source and destination address,
byte count, AZ, action and direction. It does not itself label a billed
Cross-AZ total; the related ENI/subnet is the second half of that attribution.
