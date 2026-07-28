# Production On-Demand node role pools

The production EKS Managed Node Group floor is split by operational role while
the existing Karpenter NodePools remain unchanged.

| Managed Node Group | AZ | Fixed floor | Purpose |
| --- | --- | ---: | --- |
| `system-1a` | `us-east-1a` | 1 | First system-critical failure domain |
| `system-1b` | `us-east-1b` | 1 | Second system-critical failure domain |
| `observability-1a` | `us-east-1a` | 1 | Prometheus, Grafana and Jaeger |
| `data-observability-1b` | `us-east-1b` | 1 | AZ-bound OpenSearch data node |

All groups retain `workload-class=critical` during the migration so existing
workloads continue to schedule. The additional `workload-tier` label exposes
the target role without introducing hard taints in the same rollout.

`system-*` remains the only Managed Node Group prefix controlled by Cluster
Autoscaler. The two observability role pools have
`minSize = desiredSize = maxSize = 1`.

## Storage constraint

Prometheus uses an EBS volume in `us-east-1a`; OpenSearch uses an EBS volume in
`us-east-1b`. A single node cannot mount both volumes. OpenSearch therefore
uses the data-observability node in 1b rather than the observability node in 1a.

## Rollout gates

1. Apply Terraform and wait until all five Managed Node Group nodes are Ready.
2. Verify labels, allocatable capacity, DaemonSets and EBS CSI health.
3. Move system and observability workloads incrementally through GitOps.
4. Keep application Deployments, replicas, HPA and Karpenter Spot configuration
   unchanged. No dedicated application-baseline On-Demand group is created.
5. Do not taint the new groups until every intended workload has matching
   tolerations and a tested fallback.
6. Drain old excess `system-*` nodes one at a time only after replacement
   capacity is Ready and PodDisruptionBudgets permit eviction.

## Rollback

Remove the two added groups and restore the previous `system-*` scaling
limits. Do not drain a role node until its workloads have returned to healthy
nodes and any AZ-bound volume is attached successfully.
