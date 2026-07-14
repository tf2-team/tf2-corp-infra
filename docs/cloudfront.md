# CloudFront edge (internal storefront ALB via VPC origin)

CloudFront terminates **HTTPS** at the edge and reaches the **internal** storefront ALB over a **VPC origin** (private path; ALB is not internet-facing). Sensitive admin/telemetry path prefixes are blocked with a **CloudFront Function** (viewer-request → HTTP 403). Terraform does **not** create the ALB or the ACM certificate; operators supply the **ACM certificate ARN**, **internal ALB DNS name**, **ALB ARN**, and **aliases**.

```
Browser (HTTPS) → CloudFront (ACM, us-east-1)
                      │  VPC origin (http-only :80)
                      │  + Function: block /grafana, /jaeger, …
                      ▼
               Internal ALB (frontend-proxy-public Ingress, scheme=internal)
                      │  no ALB path-block rules
                      ▼
               frontend-proxy → storefront stack
```

Module: `modules/cloudfront-alb`  
Wired in: `environments/development` and `environments/production` as `module.cloudfront_storefront`  
Default: **`cloudfront_enabled = false`** (no resources until you opt in)

---

## Free-tier / cost posture

| Setting | Value | Why |
|---|---|---|
| Price class | `PriceClass_100` (default) | US, Canada, Europe only — lowest edge footprint |
| Viewer cert | ACM + SNI-only | No dedicated IP charge |
| Cache | Managed **CachingDisabled** | Dynamic cart/API correctness |
| Path block | CloudFront Function | No WAF cost for simple prefix 403s |
| WAF | Off by default (`cloudfront_web_acl_id` unset) | Extra cost on classic PAYG; **required** on flat-rate pricing plans |
| Access logging | Off by default | Avoid S3 log bucket cost |
| Origin Shield / Lambda@Edge | Not used | Extra cost |

Account Free Tier request/data transfer quotas still apply; heavy load-generator traffic can exceed them.

### Flat-rate pricing plan + web ACL

If the distribution is subscribed to a CloudFront **flat-rate pricing plan** (Free / Pro / Business / Premium), AWS attaches a plan-managed WAFv2 web ACL and **rejects** any `UpdateDistribution` that removes or replaces it:

```text
InvalidArgument: You can't remove or replace the web ACL for your distribution.
Distributions with a pricing plan subscription must have a web ACL resource.
```

**Path A — keep the plan:** set `cloudfront_web_acl_id` to the existing ACL ARN (do not leave it null/empty).

```cmd
aws cloudfront get-distribution --id <DISTRIBUTION_ID> ^
  --query Distribution.DistributionConfig.WebACLId --output text
```

```hcl
cloudfront_web_acl_id = "arn:aws:wafv2:us-east-1:ACCOUNT:global/webacl/CreatedByCloudFront-…/…"
```

**Path B — drop plan WAF (PAYG):** cancel the pricing plan in the CloudFront console first. After the distribution is pay-as-you-go, leave `cloudfront_web_acl_id` unset (or `null`) and apply so Terraform detaches the plan-created ACL. Optionally delete the orphaned `CreatedByCloudFront-*` web ACL in the WAFv2 console afterward.

Terraform manages association only; it does **not** create or own plan-created web ACLs. Production currently uses **path B** (PAYG, no WAF).

---

## Prerequisites

1. **Internal storefront ALB healthy** — chart with `values-public-alb.yaml` (`scheme: internal`, `blockSensitivePaths: false`) and Ingress `frontend-proxy-public` has an address. Private subnets must be tagged `kubernetes.io/role/internal-elb=1` (this stack’s VPC module already tags them).
2. **ALB ARN** for that load balancer (required for VPC origin).
3. **ACM certificate ISSUED in `us-east-1`** covering every hostname in `cloudfront_aliases`.
4. **DNS control** for those aliases (CNAME or Route53 alias to the CloudFront domain after apply).

Terraform does **not** create Route53 records or ACM certificates.

---

## Inputs

| Variable | Required when enabled | Description |
|---|---|---|
| `cloudfront_enabled` | — | Gate; default `false` |
| `cloudfront_acm_certificate_arn` | Yes | ACM ARN in `us-east-1` |
| `cloudfront_origin_domain_name` | Yes | Internal ALB DNS from Ingress status |
| `cloudfront_origin_alb_arn` | Yes | Internal ALB ARN for VPC origin |
| `cloudfront_aliases` | Yes (≥1) | CNAMEs covered by the cert |
| `cloudfront_price_class` | No | Default `PriceClass_100` |
| `cloudfront_block_sensitive_paths` | No | Default **true** (prod) / **false** (dev) |
| `cloudfront_blocked_prefixes` | No | Default admin/telemetry prefixes |
| `cloudfront_web_acl_id` | When on flat-rate plan | WAFv2 global web ACL ARN; keep plan-created ACL |

---

## Enable / cutover sequence

Changing an existing **internet-facing** ALB to **internal** usually **recreates** the load balancer (new DNS name and ARN). Coordinate chart and Terraform:

### 1. Chart: internal ALB, no path blocks

Ensure Git values include `values-public-alb.yaml` with:

* `scheme: internal`
* `blockSensitivePaths: false`

Sync via Argo CD (preferred) or break-glass Helm.

If the controller does not flip scheme in place (known ALB Controller limitation), delete and re-create the Ingress so a new **internal** ALB is provisioned:

```cmd
kubectl delete ingress frontend-proxy-public -n techx-corp
REM Then Argo sync / helm upgrade so the Ingress is recreated with scheme=internal
```

Wait until the Ingress has a hostname (often `internal-…elb.amazonaws.com`).

### 2. Collect ALB DNS and ARN

**Production namespace example** (`techx-corp`):

```cmd
kubectl get ingress frontend-proxy-public -n techx-corp ^
  -o jsonpath="{.status.loadBalancer.ingress[0].hostname}"
```

```cmd
aws elbv2 describe-load-balancers --region us-east-1 ^
  --query "LoadBalancers[?DNSName=='<paste-alb-dns>'].LoadBalancerArn" ^
  --output text
```

**Development namespace example** (`techx-corp-dev`): same with that namespace.

### 3. Confirm ACM cert

```cmd
aws acm describe-certificate --region us-east-1 ^
  --certificate-arn arn:aws:acm:us-east-1:ACCOUNT:certificate/ID ^
  --query "Certificate.Status"
```

Expect `ISSUED`. Domains on the cert must include every alias.

### 4. Set `terraform.tfvars`

```hcl
cloudfront_enabled               = true
cloudfront_acm_certificate_arn   = "arn:aws:acm:us-east-1:ACCOUNT:certificate/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
cloudfront_origin_domain_name    = "internal-k8s-….elb.amazonaws.com"
cloudfront_origin_alb_arn        = "arn:aws:elasticloadbalancing:us-east-1:ACCOUNT:loadbalancer/app/…/…"
cloudfront_aliases               = ["shop.example.com"]
cloudfront_block_sensitive_paths = true
# cloudfront_price_class         = "PriceClass_100"
# Required if distribution is on a flat-rate pricing plan (keep plan-created ACL):
# cloudfront_web_acl_id          = "arn:aws:wafv2:us-east-1:ACCOUNT:global/webacl/CreatedByCloudFront-…/…"
```

### 5. Plan and apply

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
terraform -chdir=environments/production output cloudfront_domain_name
terraform -chdir=environments/production output cloudfront_distribution_id
terraform -chdir=environments/production output cloudfront_vpc_origin_id
```

Use `environments/development` for the dev stack.

**Same-account VPC origin:** CloudFront updates the ALB security group so edge traffic can reach the internal ALB. No manual prefix-list SG rules are required for the common same-account case.

### 6. DNS cutover

Create a **CNAME** (or Route53 **A/AAAA alias** to CloudFront using `cloudfront_hosted_zone_id`) from each alias to the `cloudfront_domain_name` output (e.g. `d111111abcdef8.cloudfront.net`).

### 7. Smoke test

```cmd
curl -I https://shop.example.com/
curl -I https://shop.example.com/grafana
```

Expect storefront `2xx`/`3xx` on `/`. Expect **403** on blocked prefixes when `cloudfront_block_sensitive_paths=true`.

Chart smoke script (edge host, not internal ALB):

```cmd
bash scripts/smoke-test.sh -n techx-corp -h https://shop.example.com -a https://shop.example.com
```

---

## Path blocking

| Layer | Behavior |
|---|---|
| **CloudFront** (default prod) | Function returns **403 Access Denied** for configured prefixes |
| **Internal ALB** | Forwards **all** paths to `frontend-proxy` (no fixed-response rules) |

Default blocked prefixes:

* `/grafana`, `/jaeger`, `/loadgen`, `/feature`, `/flagservice`  
  (`/otlp-http` is **not** blocked — browser web OTLP traces use the public edge)

Toggle:

```hcl
cloudfront_block_sensitive_paths = true   # or false
```

Emergency ALB-side blocks (without CloudFront) remain possible via chart:

```cmd
helm upgrade techx-corp . -n techx-corp --reuse-values ^
  --set components.frontend-proxy.publicAlb.blockSensitivePaths=true
```

Prefer CloudFront for production edge posture.

---

## Outputs

| Output | Use |
|---|---|
| `cloudfront_domain_name` | DNS target |
| `cloudfront_distribution_id` | Invalidation / console |
| `cloudfront_hosted_zone_id` | Route53 alias zone ID |
| `cloudfront_vpc_origin_id` | VPC origin resource ID |
| `cloudfront_block_sensitive_paths` | Whether Function is attached |
| `cloudfront_blocked_prefixes` | Active block list |
| `cloudfront_web_acl_id` | Attached WAFv2 ACL ARN (if set) |
| `cloudfront_bootstrap_note` | Short operator reminder |

---

## Design notes

* **VPC origin** keeps the ALB private; browsers never need a public ALB DNS.
* **Origin protocol** is `http-only` on port **80** to match chart `listenPorts` (`[{"HTTP":80}]`).
* **Cache policy** is managed **CachingDisabled** so session cookies and POSTs are not edge-cached incorrectly.
* **Origin request policy** is managed **AllViewerExceptHostHeader** so the origin Host header is the ALB DNS (empty Ingress `host`).
* **Path blocking** is a lightweight CloudFront Function (not WAF) for free-tier-friendly 403s.
* **WAF** stays optional for classic PAYG; when a flat-rate pricing plan is active, pass the plan web ACL via `cloudfront_web_acl_id` so Terraform does not clear it.

---

## Rollback

1. Point DNS away from CloudFront if needed.
2. Set `cloudfront_enabled = false` and apply (destroys distribution, VPC origin, and Function).
3. Optionally set chart `scheme: internet-facing` and re-create Ingress for a temporary public ALB (not recommended long-term).

---

## Operator admin access (Client VPN)

CloudFront **must** keep blocking admin prefixes for public users. Operators open those paths by connecting to **AWS Client VPN** and using **private DNS** (`internal.hungtran.id.vn/<service>` → internal ALB; `modules/private-dns`). There is no second admin ALB.

Full runbook (ACM import + **local client setup/connect** + private DNS): **[docs/client-vpn.md](./client-vpn.md)**.

```cmd
REM Public edge — expect 403
curl -i https://<cloudfront-alias>/grafana/

REM After Client VPN connect (see client-vpn.md "Client setup and connect")
curl -i http://internal.hungtran.id.vn/grafana/
REM Fallback if private DNS off: curl -i http://<internal-alb-dns>/grafana/
```

---

## Related

* **Why internal ALB (ADR):** [docs/adr/storefront-edge-internal-alb.md](./adr/storefront-edge-internal-alb.md) — do we need the ALB, alternatives, role split vs CloudFront
* **Client VPN (admin paths):** [docs/client-vpn.md](./client-vpn.md)
* Chart storefront Ingress: `techx-corp-chart/values-public-alb.yaml`, `templates/frontend-proxy-public-ingress.yaml`
* Infra deploy runbook: `docs/DEPLOYMENT.md`
* Change record: `docs/changes/2026-07-13-internal-alb-cloudfront-vpc-origin.md`
