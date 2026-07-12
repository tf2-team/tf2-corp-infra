# Change: CPU Architecture (amd64 vs arm64) Migration Guide

## Summary

Added an operational document that explains the differences between amd64 (x86) and arm64 (Graviton) for TechX EKS, how this repository configures managed node groups and Karpenter architecture, and bidirectional migration plans for switching node architectures safely.

## Context

Development is moving toward Graviton (`t4g.medium` + `AL2023_ARM_64_STANDARD`, Karpenter `kubernetes.io/arch=arm64`) while production remains largely on x86 managed node groups. Operators needed a single, repo-grounded reference for:

* Valid instance/AMI pairings
* Multi-arch image prerequisites
* Karpenter vs MNG interaction
* amd64 → arm64 and arm64 → amd64 cutover steps

Without this, AMI mismatches, single-arch ECR tags, and hybrid NodePools are easy to misconfigure.

## Before

* Architecture guidance was scattered across informal analysis, `karpenter.md`, `workload-placement.md`, and tfvars comments.
* No dedicated migration checklist for switching CPU architecture.
* No explicit documentation of invalid pairings (e.g. `t4g` + `AL2023_x86_64_STANDARD`).

## After

* New guide: `docs/cpu-architecture.md` covering comparison, current wiring, selection criteria, migration phases both directions, hybrid rules, troubleshooting, and copy-ready checklists.
* Cross-links added from `docs/karpenter.md` and `docs/workload-placement.md`.

## Technical Design Decisions

* **Document under `techx-corp-infra/docs/`** — node AMI, MNG, and Karpenter are infra-owned; platform multi-arch bake is referenced, not duplicated.
* **Bidirectional plans** — treat arm64→amd64 as first-class rollback, not an afterthought.
* **Multi-arch images as permanent policy** — migration assumes bake continues to publish both platforms so either node arch remains viable.
* **No Terraform code change in this change** — documentation only; live arch settings remain in env tfvars and the Karpenter module.

Alternatives considered:

* Workspace-root-only doc — rejected so infra operators find it next to `karpenter.md` / `DEPLOYMENT.md`.
* Embedding only in `DEPLOYMENT.md` — rejected; topic is large enough for a standalone guide with cross-links.

## Implementation Details

1. Authored `docs/cpu-architecture.md` with glossary, comparison tables, workspace wiring (§4), selection guidance, migration principles, amd64→arm64 and arm64→amd64 phased plans, hybrid mode, troubleshooting, and checklists.
2. Linked the new guide from `docs/karpenter.md` and `docs/workload-placement.md`.
3. Recorded this change document.

## Files Changed

**Documentation:**

* `docs/cpu-architecture.md` — New amd64/arm64 comparison and migration guide.
* `docs/karpenter.md` — Related-docs link to CPU architecture guide.
* `docs/workload-placement.md` — Related-docs link to CPU architecture guide.
* `docs/changes/2026-07-11-cpu-architecture-migration-guide.md` — This change record.

## Dependencies and Cross-Repository Impact

* **Depends on:** platform multi-arch bake contract (`techx-corp-platform/docker-bake.hcl`, `docs/CICD.md`).
* **Chart:** no code change; placement remains arch-agnostic (`workload-class`).
* **No required simultaneous PR** in platform or chart for this documentation change.

Related reading outside this repo:

* `techx-corp-platform/docs/CICD.md` — multi-arch bake platforms
* `techx-corp-chart/docs/operations/workload-placement.md` — pod scheduling (not CPU arch)

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime change (documentation only) |
| **Infrastructure** | No Terraform/resource change in this commit |
| **Deployment** | Operators gain a defined migration/rollback procedure when switching node architecture |
| **Performance** | No change |
| **Security** | No change |
| **Reliability** | Improves operational readiness for arch switches; reduces AMI/image mismatch risk when followed |
| **Cost** | No change from this doc; guide notes Graviton cost context |
| **Backward compatibility** | N/A (docs only) |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| N/A | Documentation-only | N/A |

### Manual Verification

* Reviewed current dev tfvars (`t4g.medium` + `AL2023_ARM_64_STANDARD`) and Karpenter module arch requirement against guide tables.
* Confirmed platform bake still documents `linux/amd64` + `linux/arm64`.
* Confirmed chart has no hard `kubernetes.io/arch` selectors that would conflict with either architecture.

### Remaining Verification (Post-Merge)

* When performing a live arch switch, execute the checklist in `docs/cpu-architecture.md` §11 and update §4.2 environment posture table if posture changes.

## Migration or Deployment Notes

None for applying this documentation change. For a live architecture switch, follow `docs/cpu-architecture.md` sections 6–8.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Operators follow outdated §4.2 posture table after a live switch | Medium | Low | Update §4.2 in the same PR as tfvars/module arch changes |
| Doc treated as permission to switch without multi-arch images | Low | High | Phase 0 gates in the guide require imagetools inspect |

**Rollback procedure:**

Revert the documentation files listed under Files Changed. No infrastructure rollback is implied by this change alone.
