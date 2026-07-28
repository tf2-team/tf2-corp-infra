# Capacity and Karpenter Evidence — 2026-07-28

## Snapshot

The production cluster had eight Ready nodes, four per AZ. Each node exposed `1930m` allocatable CPU and approximately `6.6–6.9 GiB` allocatable memory.

| AZ | Nodes | Observed CPU usage | Observed memory usage |
|---|---:|---:|---:|
| `us-east-1a` | 4 | `796m` | `11,384 MiB` |
| `us-east-1b` | 4 | `1,073m` | `12,299 MiB` |

These are point-in-time usage values, not scheduler requests and not proof that all pods can be rescheduled within five minutes.

## Karpenter eligibility

- `stateless-on-demand` permits `us-east-1a` and `us-east-1b`, with limits of `32 CPU` and `64 GiB`; snapshot usage was one node, `2 CPU`, approximately `7.6 GiB`, in `1a`.
- `stateless-spot` permits both AZs with the same limits; snapshot usage was two nodes, `4 CPU`, approximately `15.1 GiB`, split across both AZs.
- The discovered private subnets were available with `3,920` free IPs in `1a` and `3,918` in `1b`.
- No `FailedScheduling` event was returned at the snapshot.

## Gate result

Configuration permits Karpenter capacity in either AZ and subnet IP headroom is ample. The evidence does not measure full pod requests, EC2 quota exhaustion, Spot availability during an AZ loss, or the controlled five-minute surviving-AZ load profile.

**Capacity gate: FAIL pending a reviewed GitOps load probe in each surviving-AZ scenario.** Direct `kubectl apply` or `kubectl scale` is prohibited.

<!-- Change trail: @hungxqt - 2026-07-28 - Recorded two-AZ node, NodePool, subnet, and remaining load-proof evidence. -->
