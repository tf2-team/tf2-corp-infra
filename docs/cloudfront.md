# CloudFront free-tier edge (storefront ALB origin)

CloudFront terminates **HTTPS** at the edge and forwards traffic to the existing **internet-facing storefront ALB** (HTTP:80). Terraform does **not** create the ALB or the ACM certificate; operators supply the **ACM certificate ARN**, **ALB DNS name**, and **aliases**.

```
Browser (HTTPS) → CloudFront (ACM, us-east-1)
                      │  http-only :80
                      ▼
               Storefront ALB (frontend-proxy-public Ingress)
                      │
                      ▼
               frontend-proxy → storefront stack
```

Module: `modules/cloudfront-alb`  
Wired in: `environments/development` and `environments/production` as `module.cloudfront_storefront`  
Default: **`cloudfront_enabled = false`** (no resources until you opt in)

---

## Free-tier / cost posture

This is **not** a separate AWS product SKU. Configuration aims to stay within account Free Tier usage quotas and minimize ongoing cost:

| Setting | Value | Why |
|---|---|---|
| Price class | `PriceClass_100` | US, Canada, Europe only — lowest edge footprint |
| Viewer cert | ACM + SNI-only | No dedicated IP charge |
| Cache | Managed **CachingDisabled** | Dynamic cart/API correctness |
| WAF | Off by default | Extra cost |
| Access logging | Off by default | Avoid S3 log bucket cost |
| Origin Shield / Lambda@Edge | Not used | Extra cost |

Account Free Tier request/data transfer quotas still apply; heavy load-generator traffic can exceed them.

---

## Prerequisites

1. **Storefront public ALB healthy** — chart with `values-public-alb.yaml` (or equivalent) and Ingress `frontend-proxy-public` has an address.
2. **ACM certificate ISSUED in `us-east-1`** covering every hostname you put in `cloudfront_aliases`. CloudFront viewer certificates **must** be in `us-east-1` even if the ALB is elsewhere (this stack already uses `us-east-1`).
3. **DNS control** for those aliases (CNAME or Route53 alias to the CloudFront domain after apply).

Terraform does **not** create Route53 records or ACM certificates.

---

## Inputs

| Variable | Required when enabled | Description |
|---|---|---|
| `cloudfront_enabled` | — | Gate; default `false` |
| `cloudfront_acm_certificate_arn` | Yes | Primary input — ACM ARN in `us-east-1` |
| `cloudfront_origin_domain_name` | Yes | ALB DNS from Ingress status |
| `cloudfront_aliases` | Yes (≥1) | CNAMEs covered by the cert |
| `cloudfront_price_class` | No | Default `PriceClass_100` |

---

## Enable sequence

### 1. Get ALB DNS

**Production namespace example** (`techx-corp`):

```cmd
kubectl get ingress frontend-proxy-public -n techx-corp ^
  -o jsonpath="{.status.loadBalancer.ingress[0].hostname}"
```

**Development namespace example** (`techx-corp-dev`):

```cmd
kubectl get ingress frontend-proxy-public -n techx-corp-dev ^
  -o jsonpath="{.status.loadBalancer.ingress[0].hostname}"
```

### 2. Confirm ACM cert

```cmd
aws acm describe-certificate --region us-east-1 ^
  --certificate-arn arn:aws:acm:us-east-1:ACCOUNT:certificate/ID ^
  --query "Certificate.Status"
```

Expect `ISSUED`. Domains on the cert must include every alias.

### 3. Set `terraform.tfvars`

```hcl
cloudfront_enabled             = true
cloudfront_acm_certificate_arn = "arn:aws:acm:us-east-1:ACCOUNT:certificate/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
cloudfront_origin_domain_name  = "k8s-….elb.amazonaws.com"
cloudfront_aliases             = ["shop.example.com"]
# cloudfront_price_class       = "PriceClass_100"
```

ARN is not a secret, but avoid committing environment-specific hostnames if your policy prefers local-only tfvars overrides.

### 4. Plan and apply

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
terraform -chdir=environments/production output cloudfront_domain_name
terraform -chdir=environments/production output cloudfront_distribution_id
```

Use `environments/development` for the dev stack.

### 5. DNS cutover

Create a **CNAME** (or Route53 **A/AAAA alias** to CloudFront using `cloudfront_hosted_zone_id`) from each alias to the `cloudfront_domain_name` output (e.g. `d111111abcdef8.cloudfront.net`).

### 6. Smoke test

```cmd
curl -I https://shop.example.com/
```

Expect `2xx`/`3xx` from the storefront. Sensitive paths (`/grafana`, etc.) still return **403** when chart path blocking is on.

---

## Outputs

| Output | Use |
|---|---|
| `cloudfront_domain_name` | DNS target |
| `cloudfront_distribution_id` | Invalidation / console |
| `cloudfront_hosted_zone_id` | Route53 alias zone ID |
| `cloudfront_arn` | IAM / tagging |
| `cloudfront_status` | Expect `Deployed` |
| `cloudfront_bootstrap_note` | Short operator reminder |

---

## Design notes

* **Origin protocol** is `http-only` on port **80** to match the current public ALB `listenPorts` (`[{"HTTP":80}]`). No ALB TLS listener is required.
* **Cache policy** is managed **CachingDisabled** so session cookies and POSTs to cart/checkout are not edge-cached incorrectly.
* **Origin request policy** is managed **AllViewerExceptHostHeader** so the origin Host header is the ALB DNS (compatible with empty Ingress `host`).
* The **ALB remains internet-facing**. Clients can still hit the ALB DNS directly unless you add a follow-up lockdown (CloudFront managed prefix list / custom origin header). That is **out of scope** for v1.

---

## Rollback

1. Point DNS back to the ALB (or remove public CNAME).
2. Set `cloudfront_enabled = false` and apply (destroys the distribution).

Storefront ALB and chart Ingress are unchanged.

---

## Related

* Chart public ALB: `techx-corp-chart/values-public-alb.yaml`, `templates/frontend-proxy-public-ingress.yaml`
* Infra deploy runbook: `docs/DEPLOYMENT.md`
* Change record: `docs/changes/2026-07-13-introduce-cloudfront-alb-origin.md`
