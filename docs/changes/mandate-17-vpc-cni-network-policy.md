# Mandate 17 - AWS VPC CNI NetworkPolicy

## Scope

Enable the NetworkPolicy controller and node agent already shipped with the
production AWS VPC CNI add-on. The enforcing mode remains `standard` during the
Mandate 17 rollout so existing pods are not unexpectedly isolated at startup.

This change does not upgrade the add-on, replace the CNI, create an AWS managed
service, add nodes, change prefix delegation, or activate application policies.
Application policy remains disabled until the separate Chart activation gates
have passed.

## Expected Terraform plan

The production plan must update only the `vpc-cni` managed add-on
`configuration_values`:

- `enableNetworkPolicy: "true"`
- `NETWORK_POLICY_ENFORCING_MODE: "standard"`

The existing add-on version, `ENABLE_PREFIX_DELEGATION`, `WARM_PREFIX_TARGET`,
and container resource settings must remain unchanged.

## Post-apply verification

```powershell
$ctx = "arn:aws:eks:us-east-1:493499579600:cluster/techx-tf2-prod"

kubectl --context $ctx -n kube-system rollout status daemonset/aws-node --timeout=10m
kubectl --context $ctx -n kube-system get pods -l k8s-app=aws-node -o wide
kubectl --context $ctx get crd policyendpoints.networking.k8s.aws
kubectl --context $ctx get policyendpoints.networking.k8s.aws -A
kubectl --context $ctx -n kube-system get pods -l k8s-app=aws-node `
  -o jsonpath='{range .items[*]}{.metadata.name}{" containers="}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}'
```

Expected results:

- every `aws-node` pod is Ready, including the network-policy node agent;
- the `PolicyEndpoint` CRD exists;
- ports 8162/8163 have no node-agent conflict;
- application traffic is unchanged because Chart NetworkPolicy is still off.

## Rollback

First return Chart policy through
`enabled=true/enforceEgress=false` to `enabled=false/enforceEgress=false`. Then
remove `enableNetworkPolicy` and `NETWORK_POLICY_ENFORCING_MODE` from the CNI
configuration and apply the reviewed Terraform rollback plan. Do not uninstall
the VPC CNI or change its version during an incident.
