# ADR: Internal ALB as CloudFront VPC origin for the storefront

- **Status:** Accepted
- **Date:** 2026-07-13
- **Scope:** Storefront public edge (`CloudFront` + chart Ingress `frontend-proxy-public`)
- **Repos:** `techx-corp-infra` (CloudFront / VPC origin), `techx-corp-chart` (ALB Ingress)
- **Related ops guide:** [docs/cloudfront.md](../cloudfront.md)

---

## Context

The storefront is exposed to browsers over HTTPS at a custom domain. Traffic path after the internal-ALB cutover:

```
Browser (HTTPS)
    → CloudFront (viewer TLS, optional path-block Function)
        → VPC origin (private)
            → Internal Application Load Balancer
                → frontend-proxy pods (target-type: ip)
                    → storefront microservices
```

A natural design question is:

> **Do we really need the internal ALB?**  
> CloudFront already terminates TLS and can block sensitive paths. Is the ALB a redundant hop?

This ADR records the decision and the alternatives that were considered.

---

## Decision

**Keep an internal Application Load Balancer** as the CloudFront **VPC origin** target.

More precisely:

| Component | Required? | Role |
|---|---|---|
| **CloudFront** | Yes (for public HTTPS edge) | Viewer TLS, DNS alias, optional path 403s, free-tier-friendly edge |
| **Something in the VPC as origin** | **Yes** | CloudFront VPC origin cannot target Kubernetes pods/Services directly |
| **Internal ALB** | **Yes (chosen origin type)** | Stable private L7 front door for `frontend-proxy` via AWS Load Balancer Controller |
| **Internet-facing ALB** | **No** | Removed; browsers must not depend on a public ALB DNS |
| **ALB path-block rules** | **No (default)** | Path policy lives on CloudFront; ALB forwards all paths to frontend-proxy |

**One-line summary:** we need a private load balancer (or EC2) as the VPC origin; the internal ALB is the least-friction choice for the current Helm Ingress + AWS Load Balancer Controller design. We do **not** need a *public* ALB, and we do **not** need ALB fixed-response path rules when CloudFront owns edge policy.

---

## Why an origin inside the VPC is mandatory

CloudFront **VPC origins** only support these endpoint types:

1. Application Load Balancer  
2. Network Load Balancer  
3. EC2 instances  

There is **no** supported “CloudFront → Kubernetes Service / Pod” attachment. Multi-pod EKS workloads need a stable origin that:

* Has an address CloudFront can resolve and reach privately  
* Performs health checks and distributes traffic across pods  
* Survives pod reschedules and rolling deploys  

That role is a **load balancer** (or a set of fixed EC2 instances, which does not match this platform).

So the choice is not “ALB vs nothing.” It is:

> **Which private origin type should sit between CloudFront and the storefront pods?**

---

## Why internal ALB (this stack)

### Fits the existing control plane

* Chart Ingress `frontend-proxy-public` is already managed by **AWS Load Balancer Controller**.  
* Annotations already express scheme, target type (`ip`), and listen ports (`HTTP:80`).  
* Private subnets are tagged `kubernetes.io/role/internal-elb=1` by the VPC module.  
* Changing to internal is a **scheme annotation** change, not a new ingress product.

### Correct security split after cutover

| Concern | Owner |
|---|---|
| Public reachability | CloudFront only |
| Viewer HTTPS + custom domain | CloudFront + ACM (`us-east-1`) |
| Sensitive path 403s | CloudFront Function (`cloudfront_block_sensitive_paths`) |
| Private origin connectivity | VPC origin → internal ALB SG (same-account auto-management) |
| Pod targeting / health | Internal ALB target groups |

The ALB is **not** a second public edge. It is a **private Kubernetes ingress load balancer**.

### Minimal L7 use is still useful

Even with a single catch-all path (`/` → `frontend-proxy`), ALB still provides:

* Target-type `ip` integration with pods  
* Health checks and deregistration on pod death  
* HTTP host/path semantics compatible with the existing proxy  
* A single stable DNS name for the distribution `origin.domain_name`

Path-based **blocking** is no longer an ALB responsibility; path-based **forwarding** remains trivial and stable.

---

## Alternatives considered

### A. No load balancer (CloudFront → pods only)

**Rejected.** Not supported by CloudFront VPC origin. Unstable pod IPs and no multi-pod fan-out.

### B. Internet-facing ALB + CloudFront custom origin (previous v1)

**Rejected for long-term posture.**

* ALB remains reachable on the public internet unless locked down separately.  
* Path blocks on ALB duplicate edge policy and still leave a public surface.  
* Documented follow-up was always “lock down ALB”; internal + VPC origin is the stronger form of that lockdown.

### C. Internet-facing ALB locked to CloudFront managed prefix lists

**Rejected as primary design.**

* Still a public ALB (misconfiguration risk, scanning noise, larger blast radius).  
* Extra SG/prefix-list maintenance vs VPC origin private path.  
* Acceptable only as emergency break-glass, not the target architecture.

### D. Internal NLB as VPC origin

**Deferred / optional future simplification.**

* Valid VPC origin type.  
* Could replace ALB if the chart moved from Ingress+ALB Controller to an internal NLB Service in front of frontend-proxy only.  
* Trade-offs: less native L7 Ingress ergonomics; more chart redesign; limited benefit while path policy already lives at CloudFront.  
* Revisit only if we deliberately remove ALB Controller dependency for the storefront.

### E. Skip CloudFront; public ALB only

**Rejected** for the current product goals (custom-domain HTTPS at edge without ALB certificates, optional edge path policy, private origin).

### F. EC2 instances as VPC origin

**Rejected.** Platform is EKS-native; pinning storefront traffic to EC2 instances fights the orchestration model.

---

## Consequences

### Positive

* No public storefront ALB in the steady state.  
* Clear layering: **edge policy on CloudFront**, **pod routing on ALB**.  
* Aligns with existing chart and controller; low migration cost vs NLB rewrite.  
* Same-account VPC origin updates ALB security groups for CloudFront ENIs (no manual prefix-list dance for the common case).

### Negative / costs

* One extra hop (CloudFront → ALB → pod) vs a theoretical direct origin (unsupported).  
* Scheme change **internet-facing → internal** often **recreates** the ALB (new DNS + ARN); operators must refresh `cloudfront_origin_domain_name` and `cloudfront_origin_alb_arn`.  
* ALB hourly cost remains (small relative to EKS/NAT; see [COST.md](../COST.md)).  
* Direct curl to ALB DNS from the public internet no longer works by design (use CloudFront alias or in-cluster paths).

### Operational rules

1. Browsers and smoke tests for path blocking use the **CloudFront alias**, not the internal ALB hostname.  
2. Chart defaults: `publicAlb.scheme: internal`, `blockSensitivePaths: false`.  
3. Terraform: VPC origin + optional Function; never treat ALB path blocks as the primary prod control.  
4. Emergency only: chart may set `blockSensitivePaths: true` if CloudFront is unavailable; prefer restoring edge Function.

---

## Non-goals

* This ADR does **not** require removing the Ingress name `frontend-proxy-public` (name is historical; scheme is internal).  
* This ADR does **not** mandate WAF (optional cost); Function covers the fixed admin-prefix list.  
* This ADR does **not** put TLS on the ALB; origin protocol remains `http-only` on port 80 inside the VPC.

---

## Implementation map

| Area | Location |
|---|---|
| CloudFront + VPC origin module | `modules/cloudfront-alb/` |
| Env wiring / variables | `environments/{development,production}/` |
| Operator runbook | [docs/cloudfront.md](../cloudfront.md) |
| Chart Ingress | `techx-corp-chart/templates/frontend-proxy-public-ingress.yaml` |
| Chart values overlay | `techx-corp-chart/values-public-alb.yaml` |
| Cutover change records | `docs/changes/2026-07-13-internal-alb-cloudfront-vpc-origin.md`, chart `docs/changes/2026-07-13-internal-alb-no-path-blocks.md` |

---

## Review triggers

Re-open this ADR if any of the following become true:

* Storefront is no longer fronted by CloudFront.  
* AWS adds a first-class CloudFront origin type for EKS Services/Gateway API that we adopt.  
* We intentionally move storefront exposure to NLB-only or Gateway API and drop ALB Controller for this path.  
* Compliance requires WAF (or other edge controls) instead of/in addition to the CloudFront Function.

---

## Decision summary

| Question | Answer |
|---|---|
| Do we need a **public** ALB? | **No.** |
| Do we need **something** private for VPC origin? | **Yes.** |
| Is **internal ALB** that something for this platform today? | **Yes.** |
| Is the internal ALB “redundant” with CloudFront? | **No** — different roles (edge vs private pod load balancing). |
| Where do path blocks live? | **CloudFront** (default); ALB only as emergency break-glass. |
