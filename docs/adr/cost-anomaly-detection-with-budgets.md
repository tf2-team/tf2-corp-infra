# ADR: Cost Anomaly Detection alongside AWS Budgets (production-only)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-07-13 |
| **Pillar** | Cost Optimization |
| **Owners** | CDO-03 (Cost) |
| **Related** | COS-01 / TF2-12; `modules/cost-budgets`; `modules/cost-anomaly` |

## Context

Capstone onboarding sets a soft ceiling of **~$300 per week per TF** for all AWS spend (`phase3/onboarding/BUDGET.md`). The team already introduced **AWS Budgets** via Terraform (monthly **$900** ≈ $300×3 weeks, daily **$45**, SNS **email-json**), wired on **production only** because budgets are **account-level**.

That leaves a gap:

* Budgets fire when spend approaches a **fixed limit**.
* They do **not** answer: “Is this service’s cost **abnormally high vs recent baseline** even if we are still under the monthly budget?”

Examples that hurt a short capstone window:

* Accidental large NAT / data-transfer spike
* Runaway load-generator or mis-sized nodes
* External principal (e.g. mentor IAM) creating expensive resources

AWS **Cost Anomaly Detection** (Cost Explorer) learns spend patterns and alerts on statistical anomalies. The account already had a **Console-created** monitor (`Webapp-Group10-Services-Monitor`, threshold ~$100 / 40%) not managed by this repo.

## Decision

1. **Adopt Cost Anomaly Detection in Terraform** as a **second** cost guardrail next to Budgets — not a replacement.
2. **Implement** via `modules/cost-anomaly`:
   * Dimensional monitor on **SERVICE**
   * Subscription frequency **DAILY** (configurable)
   * EMAIL subscriber (ops mailbox)
   * Alert when **both** hold (AND): impact ≥ **$25** USD **and** ≥ **40%**
3. **Wire only `environments/production`** on shared single-account TF layouts (same rule as cost-budgets).
4. **Do not import** the existing Group10 Console monitor into Terraform state; create **TF-owned** names (`{project}-service-anomaly-*`). Operators may delete the Console monitor manually if duplicate mail is noisy.
5. **Alert only** — neither Budgets nor CAD hard-stop resources; ops still cut spend.

## Alternatives considered

| Option | Pros | Cons | Outcome |
|---|---|---|---|
| **A. Budgets only** | Simple; already built | Misses under-ceiling spikes | Rejected as sole control |
| **B. CAD only** | Good spike signal | No explicit $300/week narrative / forecast % of limit | Rejected as sole control |
| **C. Budgets + CAD (this ADR)** | Ceiling + baseline | Two alert channels; need threshold tuning | **Accepted** |
| **D. Rely on Console Group10 only** | Zero TF work | Not reviewed in PRs; foreign naming; $100 may be late for $300/week TF | Rejected for IaC ownership |
| **E. CUSTOM monitor / linked accounts** | Finer filters | Overkill for single-account capstone | Deferred |
| **F. CAD → SNS/Telegram** | Unified with mentor/flagd channels | Extra IAM/SNS wiring for CE | Deferred; native EMAIL first |
| **G. Wire CAD on development too** | “Same as prod” | **Duplicate account-level** resources | **Rejected** |

## Consequences

### Positive

* Versioned, reviewable cost spike detection in `techx-corp-infra`.
* Clear split: **Budgets = ceiling**, **CAD = anomaly vs baseline**.
* Lower absolute threshold ($25) than Group10 ($100) fits a small weekly budget.

### Negative / trade-offs

* Possible **duplicate email** if Group10 monitor remains.
* CAD needs **history** to be smart; early days may be quiet or coarse.
* DAILY frequency is not real-time (use IMMEDIATE via tfvars if needed).
* Two modules to disable on teardown (`cost_budgets`, `cost_anomaly`).

### Neutral

* Email address lives in production `terraform.tfvars` (not a secret).
* No application or EKS runtime impact.

## Implementation map

| Piece | Location |
|---|---|
| Module | `modules/cost-anomaly/` |
| Production wire | `environments/production/main.tf` → `module.cost_anomaly` |
| Tfvars | `cost_anomaly_enabled`, `cost_anomaly_alert_email`, frequency, thresholds |
| Budgets sibling | `modules/cost-budgets/` + production wire |
| Backlog | `docs/backlogs/2026-07-13-cos-01-cost-anomaly-detection.md` |
| Change record | `docs/changes/2026-07-13-introduce-cost-anomaly-detection.md` |

## Non-goals

* Hard spending caps or Service Control Policies that deny APIs.
* Per-environment cost allocation tags as the primary CAD dimension (may revisit).
* Replacing SNS budget alerts with CAD digests.
* Managing the pre-existing Group10 Console resources in Terraform.

## Review triggers

Re-open this ADR if:

* AWS account is split so dev/prod no longer share billing scope.
* Capstone budget model changes (e.g. real weekly budget product appears).
* Alert noise forces threshold/frequency redesign or SNS fan-out.
* Multi-account / Organizations linked-account monitors become required.

## References

* `phase3/onboarding/BUDGET.md`
* `docs/changes/2026-07-13-introduce-aws-cost-budgets.md`
* AWS: Cost Anomaly Detection, AWS Budgets
