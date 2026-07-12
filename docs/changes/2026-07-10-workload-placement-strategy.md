# Change: Workload Placement Strategy (Critical MNG vs Spot Workers)

## Summary

Documented an operational strategy to place **critical** workloads (cluster system components and stateful application data) on **managed node groups**, and **stateless / interruptible** application pods on **Karpenter Spot** workers. No cluster runtime configuration was changed in this commit; implementation is phased and cross-repository.

## Context

Karpenter was introduced to grow worker capacity from Pending pods, with Spot preferred in development. Managed node groups remain the system floor, but pods were not classified or scheduled by criticality. Critical and stateless workloads could pack onto the same nodes, so Spot reclamation or MNG saturation could affect Postgres, Kafka, Valkey, or control-plane-adjacent operators.

This strategy is needed so operators and future chart/infra changes share one placement model before coding labels, taints, and `schedulingRules`.

## Before

* MNG + Karpenter coexist; docs describe capacity provisioning only (`docs/karpenter.md`).
* Chart supports `schedulingRules` but defines no critical vs Spot defaults.
* Dev MNG uses Spot capacity; prod MNG is On-Demand; no `workload-class` labels.
* No written classification of which demo components are critical vs Spot-tolerant.

## After

* Strategy guide: `docs/workload-placement.md` (classification, phases, risks).
* Cross-link from `docs/karpenter.md` §10.1.
* **Phase 1 implementation landed in a follow-up change** — see `docs/changes/2026-07-10-implement-workload-placement-phase1.md` (and chart counterpart). This file remains the strategy-only record from the initial docs commit.

## Technical Design Decisions

* **MNG for critical, Karpenter Spot for elastic apps** — reuses existing capacity model; avoids stateful-on-Spot and “critical depends on Karpenter only.”
* **Soft then hard enforcement** — reduces risk of mass Pending pods when taints land before tolerations.
* **Labels `workload-class=critical|spot-tolerant`** — stable selector independent of NodePool names.
* **Prefer Spot affinity (not hard nodeSelector) for apps** — preserves On-Demand fallback when Spot is scarce.

Alternatives rejected for v1: EKS Auto Mode (larger ops shift); Cluster Autoscaler-only Spot matrix (less flexible); pure preferred affinity forever without taints (MNG still filled by stateless pods).

## Implementation Details

1. Authored `docs/workload-placement.md` with architecture diagram (ASCII), classification tables, YAML examples for chart `schedulingRules`, env policy, risks, and cross-repo impact.
2. Linked strategy from `docs/karpenter.md` so capacity and scheduling docs stay connected.
3. Concrete Terraform/chart wiring is recorded in the Phase 1 implementation change document.

## Files Changed

**Documentation:**

* `docs/workload-placement.md` — Full placement strategy.
* `docs/karpenter.md` — Added §10.1 pointer to workload placement.
* `docs/changes/2026-07-10-workload-placement-strategy.md` — This change record.

## Dependencies and Cross-Repository Impact

Strategy implementation (future) spans:

* **techx-corp-infra** — MNG labels/taints/capacity_type; Karpenter NodePool labels; system Helm nodeSelectors.
* **techx-corp-chart** — `schedulingRules` for StatefulSets vs Deployments; values overlays.
* **techx-corp-platform** — None expected for placement.

Related chart change document should be created when Phase 1 chart values land.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime change yet (docs only) |
| **Infrastructure** | No apply required for this commit |
| **Deployment** | Operators should read strategy before Phase 1 PR |
| **Performance** | N/A (docs) |
| **Security** | N/A (docs) |
| **Reliability** | Strategy, once implemented, improves isolation of stateful/system pods from Spot interrupt |
| **Cost** | Strategy, once implemented, may raise fixed MNG cost (dev OD floor) while lowering elastic Spot app cost |
| **Backward compatibility** | Documentation only; fully backward-compatible |
| **Observability** | Recommends DaemonSet tolerations so OTel agent remains on all nodes after taints |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| N/A (markdown docs) | — | N/A |

### Manual Verification

* Reviewed strategy against current `environments/development/terraform.tfvars` (MNG Spot, Karpenter Spot preferred) and chart `schedulingRules` support in `templates/_objects.tpl`.
* Confirmed stateful components in chart values: `kafka`, `postgresql`, `valkey-cart`, `opensearch`.

### Remaining Verification (Post-Merge)

* Stakeholder review of §4 classification (especially `frontend-proxy`, `flagd`, Prometheus/Grafana).
* Phase 1 implementation PR + live `kubectl get pods -o wide` validation.

## Migration or Deployment Notes

None for this documentation-only change. When implementing Phase 1:

1. Prefer relabeling MNG and chart rules before applying taints.
2. Switch dev MNG to On-Demand if critical isolation is required.
3. Apply system component nodeSelectors (Karpenter, ESO, Argo CD, metrics-server) with critical apps.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Classification disagreement delays implement | Medium | Low | Soft Phase 1; adjust component lists in follow-up |
| Readers assume strategy is already enforced | Medium | Medium | Summary and After sections state docs-only |

**Rollback procedure:**

Delete or revert the documentation files listed above. No infrastructure rollback.
