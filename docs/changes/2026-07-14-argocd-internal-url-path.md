# Change: Argo CD UI on internal private DNS path (`/argocd`)

## Summary

Configured Argo CD for path-based access behind the existing internal storefront ALB / private DNS hostname so operators can open `https://internal.hungtran.id.vn/argocd/` over Client VPN instead of relying on `kubectl port-forward`. CloudFront blocks public `/argocd`.

## Context

Argo CD was installed ClusterIP-only with documented port-forward access. Other operator UIs (Grafana, Jaeger, loadgen, feature flags) already use `https://internal.hungtran.id.vn/<service>/` via frontend-proxy on the internal ALB. Operators expect the same pattern for GitOps UI.

## Before

* `modules/argocd`: `server.insecure=false`, no `server.rootpath` / `server.basehref`, no `url` in argocd-cm.
* Access: `kubectl -n argocd port-forward svc/argocd-server 8080:443`.
* CloudFront blocked prefixes: `/grafana`, `/jaeger`, `/loadgen`, `/feature` (no `/argocd`).
* Private DNS service path map had no `argocd` entry.

## After

* Argo CD serves HTTP with `server.rootpath` / `server.basehref` = `/argocd` (default).
* Production sets `argocd-cm` `url` to `https://internal.hungtran.id.vn/argocd` when private DNS is enabled.
* Localhost port-forward remains fully supported: `kubectl port-forward service/argocd-server 8080:80 -n argocd` → `http://localhost:8080/argocd/`.
* CloudFront default blocked list includes `/argocd`.
* Private DNS outputs document `/argocd/`.

## Technical Design Decisions

* **Path via frontend-proxy Envoy (platform), not a second ALB Ingress:** Avoids recreating the internal ALB (CloudFront VPC origin + private DNS already pin a specific ALB ARN). Matches Grafana/Jaeger path model.
* **`server.insecure=true`:** TLS terminates at the internal ALB (HTTPS for VPN operators). Envoy speaks plain HTTP to `argocd-server:80` — same posture as Grafana on port 80.
* **Still no public Ingress on Argo CD Service:** Exposure is only through the internal ALB path surface; CloudFront must 403 `/argocd` for internet users.
* **Rejected:** Shared ALB Ingress group for Argo CD alone — would force `group.name` on `frontend-proxy-public` and risk ALB replace/migration for origin ARN updates.

## Implementation Details

1. Extended `modules/argocd` with `server_rootpath`, `server_url`, `server_insecure` and Helm values wiring.
2. Production module call derives `server_url` from private DNS zone when not overridden.
3. Development keeps the same rootpath for image parity; URL empty by default (port-forward).
4. Added `/argocd` to CloudFront blocked prefix defaults (module + env vars).
5. Added `argocd = "/argocd/"` to private DNS service path maps.
6. Documented access in `docs/client-vpn.md`, `docs/cloudfront.md`, `docs/DEPLOYMENT.md`.

## Files Changed

**Module:**
* `modules/argocd/main.tf` — rootpath, insecure, optional url.
* `modules/argocd/variables.tf` — new variables.
* `modules/argocd/outputs.tf` — UI path/URL outputs; port-forward HTTP:80.

**Environments:**
* `environments/production/main.tf`, `variables.tf`, `outputs.tf`
* `environments/development/main.tf`, `variables.tf`, `outputs.tf`

**Edge / DNS defaults:**
* `modules/cloudfront-alb/variables.tf` — block `/argocd`
* `modules/private-dns/variables.tf`, `main.tf` — service path + comment

**Documentation:**
* `docs/client-vpn.md`, `docs/cloudfront.md`, `docs/DEPLOYMENT.md`
* `docs/changes/2026-07-14-argocd-internal-url-path.md` — this change record

## Dependencies and Cross-Repository Impact

* **techx-corp-platform:** frontend-proxy Envoy must route `/argocd/` → `argocd-server.argocd.svc.cluster.local:80` and a new image must be published.
* **techx-corp-chart:** `ARGOCD_HOST` / `ARGOCD_PORT` env on frontend-proxy; optional NetworkPolicy egress; image tag promote after bake.
* Related: chart/platform change docs with the same date/topic.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Argo CD UI under `/argocd`; port-forward path changes to HTTP + `/argocd/` |
| **Infrastructure** | Helm values change on existing Argo CD release; CloudFront Function code regenerates with new blocked prefix |
| **Deployment** | Terraform apply (prod/dev as enabled) + platform image + chart sync |
| **Security** | UI still VPN/private; public edge 403 for `/argocd` |
| **Backward compatibility** | Break-glass port-forward command changes (443→80); bookmarks at `/` alone no longer work |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Terraform fmt | `terraform fmt` on touched paths | ✅ Applied |

### Manual Verification

Post-merge / post-apply (operator):

1. `terraform -chdir=environments/production plan` — expect Argo CD Helm upgrade + CloudFront function update.
2. On VPN: `curl -i https://internal.hungtran.id.vn/argocd/` → 200 or Argo login (after frontend-proxy image with route is live).
3. Public: `curl -i https://shop.hungtran.id.vn/argocd/` → 403.
4. Break-glass: port-forward 8080:80 → `http://localhost:8080/argocd/`.

### Remaining Verification (Post-Merge)

* Apply production Terraform after chart/platform routes are ready (order flexible: Argo rootpath before Envoy route shows 404 from Envoy; Envoy before rootpath may 404/redirect inside Argo).
* Confirm admin login and Application list in UI.

## Migration or Deployment Notes

1. Apply infra (Argo CD Helm values + CloudFront block list):

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
```

2. Deploy platform frontend-proxy image containing Envoy `/argocd` route (full release bake + chart tag promote as usual).

3. On Client VPN:

```cmd
curl -i https://internal.hungtran.id.vn/argocd/
```

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Envoy image not yet deployed while rootpath set | Medium | Low | UI via port-forward at `/argocd/` until image lands |
| CloudFront Function update brief edge change | Low | Low | Only adds blocked prefix; storefront paths unchanged |
| Operators still use old port-forward :443 | Medium | Low | Docs + outputs updated |

**Rollback procedure:**

1. Set `argocd_server_rootpath = ""` and `argocd_server_insecure = false` (or previous values) and re-apply module.
2. Remove `/argocd` from `cloudfront_blocked_prefixes` if desired.
3. Revert this change document’s code paths via Git revert.
