# AIOps long-run Karpenter memory floor

The temporary AIOps 1,000-user profile runs an OpenTelemetry Collector agent
on every worker node. A 4GiB `t4g.medium` can be filled by one application pod
and system DaemonSets, leaving the Collector Pending and creating observability
gaps.

Production Karpenter NodePools now require at least 8192MiB of instance memory.
This permits `t4g.large` and larger Graviton instances while excluding 4GiB
`t4g.medium` nodes. The existing 2-vCPU floor is unchanged.

This is a temporary AIOps load-test capacity setting. Reassess the floor and
its cost after the long-running collection is complete. Existing 4GiB nodes
are not replaced immediately; after Terraform apply, let Karpenter consolidate
them or drain them under the approved maintenance procedure.
