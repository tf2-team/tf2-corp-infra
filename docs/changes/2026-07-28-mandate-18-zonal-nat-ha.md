# Mandate 18 — production NAT per Availability Zone

## Change

Production now declares `nat-1b` in the `us-east-1b` public subnet. The
`priv-1b` and `priv-1b-nodes` route tables use that NAT; `us-east-1a` subnets
continue to use `nat-1a`.

## Why

The cluster already schedules workloads across both AZs, while the previous
shared NAT lived only in `us-east-1a`. A failure of that AZ therefore removed
Internet and public AWS API access for workloads that were otherwise healthy
in `us-east-1b`.

This affects more than optional Internet traffic: ECR image pulls, Argo CD
repository refresh, External Secrets, Karpenter/Cluster Autoscaler/AWS Load
Balancer Controller reconciliation, flagd's protected HTTP source, and the
checkout durable-outbox path to DynamoDB all require egress today. Internal
Kubernetes service traffic and the Linkerd data plane remain local to the
cluster.

## Cost and follow-up

The additional NAT has a fixed hourly and public-IPv4 cost. It is deliberately
accepted as a production resilience cost; it is not justified by NAT capacity.
The next Mandate 18 work is to reduce traffic and dependency on NAT with
targeted VPC endpoints, beginning with the no-hourly-cost DynamoDB Gateway
Endpoint for the checkout outbox. Do not remove either NAT before those
dependencies and their failure modes are re-evaluated.

## Expected Terraform plan

The plan must create one EIP, one NAT Gateway, and one private route table for
`nat-1b`, then replace the route-table associations for only `priv-1b` and
`priv-1b-nodes`. It must not replace the VPC, EKS cluster, public subnets, or
the existing `nat-1a`.

## Verification after approved apply

1. Both NAT Gateways are `Available`, one in each public subnet/AZ.
2. Each `priv-1b*` route table sends `0.0.0.0/0` to `nat-1b`; each `priv-1a*`
   route table continues to use `nat-1a`.
3. From a pod scheduled in each AZ, verify DNS and an approved external/AWS
   endpoint; verify Argo CD, External Secrets, and checkout outbox remain
   healthy.
