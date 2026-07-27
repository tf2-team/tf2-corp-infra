# Mandate 18 — beyond-compute cost audit and safe cleanup plan

## Scope and baseline

This audit was run against the production account and cluster on 2026-07-28.
It uses usage and resource state rather than credit-backed dollar totals.

- OpenSearch persistent volume: 79 GiB provisioned, 20 GiB used.
- Prometheus persistent volume: 48 GiB provisioned, 4.5 GiB used.
- All attached EBS volumes inspected are `gp3`.
- NAT Gateway `ErrorPortAllocation` remained zero. The second NAT is retained for
  Availability Zone failure containment, not because the first NAT was saturated.

## Completed network resilience change

Production now has one NAT Gateway in each Availability Zone. The `us-east-1b`
private route tables use `nat-1b`; the `us-east-1a` tables use `nat-1a`. This
removes the prior single-AZ egress dependency.

The next reduction is defined in
[2026-07-28-mandate-18-dynamodb-gateway-endpoint.md](./2026-07-28-mandate-18-dynamodb-gateway-endpoint.md): a no-hourly-cost DynamoDB Gateway Endpoint for the checkout durable outbox. It is deliberately limited to DynamoDB. Public APIs, ECR, GitOps source access, flagd's protected HTTP source, and third-party model APIs still need controlled Internet egress.

## Orphans found — do not delete before evidence capture

One EBS volume is safe to remove after the evidence below is captured:

| Resource | Evidence | Reason it is unused | Required safe sequence |
|---|---|---|---|
| `vol-0807f3ccbbfbf3bec` (`enc-grafana`, 1 GiB, gp3) | EC2 reports `available`; Kubernetes PV `pv-enc-grafana` is `Released` | Current `techx-corp-prod/grafana` PVC is bound to `pvc-c4891d4d-454d-4282-b69a-dc949615f3c2`, not this PV. | Delete the released PV, confirm the Grafana PVC remains `Bound`, then delete this EBS volume. |

The audit also found two detached target groups in old VPCs:

- `k8s-techxcor-frontend-b0a15ed388` in `vpc-0ab148fd0ebf928c3`;
- `k8s-techxtf2-frontend-ab2f09ada1` in `vpc-028af386faae8a9ce`.

They are candidates for deletion, but their target health, tags, and absence from
every active load balancer must be captured before removing them. Do not delete a
target group merely because it is detached: an external or migration workflow may
still refer to it.

Before the cleanup, capture these two console images for the Mandate evidence:

1. EC2 **Volumes**, filtered to `State = available`, showing `vol-0807f3ccbbfbf3bec`.
2. EC2 **Target Groups**, with the old detached target groups selected and the **Load balancers** tab empty.

After cleanup, capture the same filters showing no unused volume/approved detached target groups. Also capture Grafana's storefront SLO dashboard for 15–30 minutes after the cleanup.

## Lifecycle and observability guardrails

Backup policies already retain hourly recovery points for 7 days and daily recovery
points for 14 days. They must not be shortened until the team explicitly decides
that the resulting recovery-point objective remains acceptable. In particular,
the 80 GiB OpenSearch volume can contribute materially to backup storage even
though EBS snapshots are incremental.

Telemetry remains bounded: Prometheus is configured for a 2-day retention and
the normal production OpenSearch log retention is 24 hours. The temporary AIOps
long-run overlay is not part of the normal Argo CD value-file set. Retention and
sampling must be changed as a pair with a query/incident-investigation check;
deleting telemetry to save space without that check would violate the mandate.

## Evidence still required for sign-off

1. NAT Gateway `BytesInFromSource` and `BytesOutToDestination` for seven days,
   before and after the DynamoDB endpoint is applied.
2. Endpoint route-table associations plus a successful checkout/outbox trace.
3. EBS and target-group before/after cleanup images described above.
4. OpenSearch/Prometheus storage-use images and a 15–30 minute SLO dashboard.
