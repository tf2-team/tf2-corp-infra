# AWS Client VPN — private admin access (internal ALB + EKS API)

Client VPN lets operators reach:

1. The **existing internal** storefront ALB (Ingress `frontend-proxy-public`) for admin/observability paths that CloudFront blocks for the public internet.
2. The **EKS private Kubernetes API** (TCP 443) when the cluster hostname resolves to VPC ENI IPs while on VPN.

```
Browser (public HTTPS)
    → CloudFront (path 403: /grafana, /jaeger, …)
        → VPC origin → Internal ALB → frontend-proxy

Operator laptop
    → AWS Client VPN (mutual TLS, split tunnel)
        → Internal ALB (same ALB; all paths open) → frontend-proxy
        → EKS private API :443 (cluster SG allows Client VPN association SG)

Operator laptop (no VPN)
    → EKS public API :443 (when endpoint_public_access=true; dual access)
```

| Entry | Storefront | Admin paths | `kubectl` / Helm |
|---|---|---|---|
| CloudFront alias | Allowed | **403** when `cloudfront_block_sensitive_paths=true` | N/A |
| Internet → internal ALB | Not reachable (private) | Not reachable | N/A |
| Client VPN → internal ALB DNS | Allowed | **Allowed** (Grafana/Jaeger app auth still applies) | N/A |
| No VPN → EKS public endpoint | N/A | N/A | **Allowed** when public access is on |
| Client VPN → EKS private API | N/A | N/A | **Allowed** (cluster SG TCP 443 from Client VPN association SG) |

Module: `modules/client-vpn`  
Wired in: `environments/development` and `environments/production` as `module.client_vpn`  
Default: **`client_vpn_enabled = false`** (no resources until you opt in)

**Do not** create a second admin ALB. Reuse the CloudFront VPC-origin ALB. See [ADR: internal ALB](./adr/storefront-edge-internal-alb.md).

---

## Cost posture

| Item | Notes |
|---|---|
| Endpoint association | Charged **per associated subnet** (~$0.10/hour) — default is **one** private AZ |
| Active connection | Per concurrent client (~$0.05/hour) |
| Data processing | Per GB over VPN |
| Connection logs | CloudWatch retention default **14 days** |

Idle but associated endpoints still bill association hours. For class/demo cost control, set `client_vpn_enabled = false` and apply to destroy.

---

## Prerequisites (checklist)

Complete these **before** `client_vpn_enabled = true` and `terraform apply`.

| # | Prerequisite | tfvars / use |
|---|---|---|
| 1 | Internal storefront ALB healthy (`values-public-alb.yaml`: `scheme: internal`, no ALB path blocks) | — |
| 2 | **Server certificate** imported into ACM (`us-east-1`) | `client_vpn_server_certificate_arn` |
| 3 | **Client CA certificate** imported into ACM (`us-east-1`) | `client_vpn_client_ca_arn` |
| 4 | At least one **operator client cert** signed by that CA (kept on laptop for `.ovpn`) | Not in Terraform |
| 5 | Recommended: internal ALB **security group ID(s)** | `client_vpn_alb_security_group_ids` |
| 6 | Optional: private subnet IDs for association | `client_vpn_subnet_ids` (empty = first private subnet) |

Terraform does **not** generate private keys or ACM certificates.

### Import vs Request in ACM (important)

| ACM action | Use for Client VPN? |
|---|---|
| **Import certificate** | **Yes** — standard path for both server cert and client CA |
| **Request public certificate** (DNS/email validation) | **No** for the client CA; optional/uncommon for the VPN server cert. Public ACM certs are for public hostnames (e.g. CloudFront `shop…`), not for signing VPN client certs |

You need **two separate ACM certificates** (two ARNs). ACM **`import-certificate` always requires `--private-key`** — you cannot import a bare `.crt` without a key.

| tfvars key | What to import | Files |
|---|---|---|
| `client_vpn_server_certificate_arn` | VPN **server** leaf + key (+ optional chain) | `server.crt`, `server.key`, chain `ca.crt` |
| `client_vpn_client_ca_arn` | **Client CA** cert + CA private key (used as `root_certificate_chain_arn`) | `ca.crt`, `ca.key` |

Per-user `client1.crt` / `client1.key` stay on the operator machine for the `.ovpn` file; they are **not** required in ACM (unless you choose to import a sample client cert instead of the CA — not the default here).

---

## Prerequisites setup

### A. Generate PKI (operator-owned)

Work **outside the git repo**. Never commit `*.key` files.

```cmd
mkdir client-vpn-pki
cd client-vpn-pki

REM === 1) CA — public cert becomes client_vpn_client_ca_arn ===
openssl genrsa -out ca.key 2048
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt -subj "/CN=TechX Client VPN CA"

REM === 2) Server — becomes client_vpn_server_certificate_arn ===
REM CRITICAL:
REM  - CN/SAN must be an FQDN (bare CN=server => ACM DomainName empty => CreateClientVpnEndpoint fails)
REM  - Must include Key Usage + extendedKeyUsage=serverAuth (AWS VPN Client uses remote-cert-tls server;
REM    missing KU => "Certificate does not have key usage extension" / TLS handshake failed)
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=server.clientvpn.techx.local"
(
echo basicConstraints=CA:FALSE
echo keyUsage=critical,digitalSignature,keyEncipherment
echo extendedKeyUsage=serverAuth
echo subjectAltName=DNS:server.clientvpn.techx.local
) > server-ext.cnf
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 825 -extfile server-ext.cnf

REM === 3) Operator client (for .ovpn only; not imported to ACM) ===
openssl genrsa -out client1.key 2048
openssl req -new -key client1.key -out client1.csr -subj "/CN=client1"
(
echo basicConstraints=CA:FALSE
echo keyUsage=critical,digitalSignature
echo extendedKeyUsage=clientAuth
) > client-ext.cnf
openssl x509 -req -in client1.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out client1.crt -days 825 -extfile client-ext.cnf
```

```sh
# sh/bash: same PKI with KU/EKU extensions
mkdir -p client-vpn-pki && cd client-vpn-pki
openssl genrsa -out ca.key 2048
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt -subj "/CN=TechX Client VPN CA"
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=server.clientvpn.techx.local"
cat > server-ext.cnf <<'EOF'
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:server.clientvpn.techx.local
EOF
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 825 -extfile server-ext.cnf
openssl genrsa -out client1.key 2048
openssl req -new -key client1.key -out client1.csr -subj "/CN=client1"
cat > client-ext.cnf <<'EOF'
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
EOF
openssl x509 -req -in client1.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out client1.crt -days 825 -extfile client-ext.cnf
```

Files:

| File | Purpose |
|---|---|
| `ca.crt` + `ca.key` | Import together → `client_vpn_client_ca_arn` (ACM requires the key) |
| `ca.key` | Also keep offline to sign more client certs later |
| `server.crt` + `server.key` (+ `ca.crt` as chain) | Import → `client_vpn_server_certificate_arn` (must have FQDN domain) |
| `client1.crt` + `client1.key` | Append to `.ovpn` after export (not imported to ACM) |

### B. Import **both** certificates into ACM (`us-east-1`)

Region must match the VPC (`us-east-1` for this stack). Console: **Certificate Manager** → **Import** (not Request).

Both imports need `--certificate` **and** `--private-key`. That is an ACM API requirement (not optional for “CA-only”).

**B1 — Server certificate** → `client_vpn_server_certificate_arn`

```cmd
cd /d client-vpn-pki

aws acm import-certificate --region us-east-1 ^
  --certificate fileb://server.crt ^
  --private-key fileb://server.key ^
  --certificate-chain fileb://ca.crt ^
  --tags Key=Name,Value=techx-client-vpn-server
```

Copy `CertificateArn` from the response, for example:

```text
arn:aws:acm:us-east-1:493499579600:certificate/<SERVER-ID>
```

**B2 — Client CA certificate** → `client_vpn_client_ca_arn`

Import the CA **with its private key** (this is the cert ACM uses as the mutual-auth root chain):

```cmd
aws acm import-certificate --region us-east-1 ^
  --certificate fileb://ca.crt ^
  --private-key fileb://ca.key ^
  --tags Key=Name,Value=techx-client-vpn-client-ca
```

If the CLI still rejects a self-signed CA (rare), import a **client** leaf instead (signed by the same CA) and use that ARN as `client_vpn_client_ca_arn` — Client VPN still trusts clients signed by the same CA:

```cmd
aws acm import-certificate --region us-east-1 ^
  --certificate fileb://client1.crt ^
  --private-key fileb://client1.key ^
  --certificate-chain fileb://ca.crt ^
  --tags Key=Name,Value=techx-client-vpn-client-root-ref
```

Copy the second `CertificateArn`:

```text
arn:aws:acm:us-east-1:493499579600:certificate/<CA-OR-CLIENT-REF-ID>
```

**List / confirm both:**

```cmd
aws acm list-certificates --region us-east-1 --output table
aws acm describe-certificate --region us-east-1 ^
  --certificate-arn arn:aws:acm:us-east-1:ACCOUNT:certificate/SERVER-OR-CA-ID ^
  --query "Certificate.{Arn:CertificateArn,Domain:DomainName,Type:Type,InUse:InUseBy}" --output table
```

Imported certs show as type **IMPORTED**. You should have **two different ARNs** — do not reuse one ARN for both variables.

**Server cert domain check (required before apply):**

```cmd
aws acm describe-certificate --region us-east-1 ^
  --certificate-arn arn:aws:acm:us-east-1:ACCOUNT:certificate/SERVER-ID ^
  --query "Certificate.DomainName" --output text
```

| Result | Meaning |
|---|---|
| `server.clientvpn.techx.local` (or your FQDN) | OK — use this ARN as `client_vpn_server_certificate_arn` |
| `None` / empty / `null` | **Not usable** for Client VPN server. Re-generate with an FQDN CN (+ SAN), re-import, update tfvars. Do **not** use the client CA ARN as the server cert. |

> **Security:** ACM will store the CA private key for the client-CA import. Restrict IAM who can export/manage ACM certs; keep a local backup of `ca.key` offline and never commit it to git.

### C. Discover ALB security groups (recommended)

Terraform can open TCP **80** from the VPN client CIDR on these SGs so admin paths work after connect. Prefer **all** SGs currently attached to the storefront ALB.

From `cloudfront_origin_alb_arn` in tfvars (production example):

```cmd
aws elbv2 describe-load-balancers --region us-east-1 ^
  --load-balancer-arns arn:aws:elasticloadbalancing:us-east-1:493499579600:loadbalancer/app/k8s-techxcor-frontend-ae4ef3a99c/67565bb9a2abe1fb ^
  --query "LoadBalancers[0].SecurityGroups" --output text
```

From ALB DNS (Ingress hostname or `cloudfront_origin_domain_name`):

```cmd
aws elbv2 describe-load-balancers --region us-east-1 ^
  --query "LoadBalancers[?DNSName=='internal-k8s-….us-east-1.elb.amazonaws.com'].SecurityGroups" --output text
```

Example shape in tfvars (use **your** live IDs, not placeholders):

```hcl
client_vpn_alb_security_group_ids = [
  "sg-085f3775c0408abb0",
  "sg-0bd7e89c21dffcd55",
]
```

Do **not** set Ingress `alb.ingress.kubernetes.io/inbound-cidrs` to only the VPN client CIDR — that can break CloudFront VPC origin access to the same ALB.

### D. Subnet association (optional)

| Approach | tfvars |
|---|---|
| **Default (recommended for cost)** | Omit `client_vpn_subnet_ids` or set `[]` — module uses the **first private subnet** only (~1 association hour charge) |
| Explicit one AZ | `client_vpn_subnet_ids = ["subnet-…"]` |
| Multi-AZ | List two private subnet IDs (higher association cost) |

Discover private subnets:

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production output private_subnet_ids
```

Or from the ALB’s subnets:

```cmd
aws elbv2 describe-load-balancers --region us-east-1 ^
  --load-balancer-arns arn:aws:elasticloadbalancing:us-east-1:493499579600:loadbalancer/app/k8s-techxcor-frontend-ae4ef3a99c/67565bb9a2abe1fb ^
  --query "LoadBalancers[0].AvailabilityZones[*].SubnetId" --output text
```

### E. Client CIDR (defaults)

| Environment | VPC CIDR | `client_vpn_client_cidr_block` |
|---|---|---|
| Production | `10.0.0.0/16` | `10.100.0.0/22` |
| Development | `10.1.0.0/16` | `10.101.0.0/22` |

Must **not** overlap the VPC CIDR. AWS Client VPN client CIDR is typically `/22`–`/12`.

---

## Inputs

| Variable | Required when enabled | Description |
|---|---|---|
| `client_vpn_enabled` | — | Gate; default `false` |
| `client_vpn_server_certificate_arn` | Yes | ACM **server** cert ARN (imported; same region as VPC) |
| `client_vpn_client_ca_arn` | Yes | ACM **client CA** cert ARN (imported `ca.crt` + `ca.key`) |
| `client_vpn_client_cidr_block` | No | Prod `10.100.0.0/22`; dev `10.101.0.0/22` |
| `client_vpn_subnet_ids` | No | Empty = first private subnet only |
| `client_vpn_split_tunnel` | No | Default `true` |
| `client_vpn_alb_security_group_ids` | Recommended | Internal ALB SG(s); TCP 80 from Client VPN association SG |
| *(wired automatically)* `eks_cluster_security_group_ids` | Yes when enabled | Env stack passes `module.eks.cluster_security_group_id`; TCP **443** from Client VPN association SG (SG-to-SG; client CIDR alone is not enough) |

---

## Enable sequence

### 1. Set tfvars

Complete **Prerequisites setup** (sections A–E) first, then paste **real** ARNs and SG IDs (never leave `ACCOUNT` / `SERVER-CERT-ID` placeholders).

**Production example:**

```hcl
client_vpn_enabled                = true
client_vpn_client_cidr_block      = "10.100.0.0/22"
client_vpn_server_certificate_arn = "arn:aws:acm:us-east-1:493499579600:certificate/<SERVER-ID>"
client_vpn_client_ca_arn          = "arn:aws:acm:us-east-1:493499579600:certificate/<CA-ID>"
client_vpn_alb_security_group_ids = [
  "sg-085f3775c0408abb0",
  "sg-0bd7e89c21dffcd55",
]
# omit client_vpn_subnet_ids for default first private subnet
```

**Development** uses `client_vpn_client_cidr_block = "10.101.0.0/22"` (VPC is `10.1.0.0/16`).

### 2. Apply

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
terraform -chdir=environments/production output client_vpn_endpoint_id
terraform -chdir=environments/production output client_vpn_export_client_config_command
```

Association can take several minutes to become available. Confirm before connecting from a laptop:

```cmd
aws ec2 describe-client-vpn-endpoints --region us-east-1 ^
  --query "ClientVpnEndpoints[*].{Id:ClientVpnEndpointId,Status:Status.Code,Dns:DnsName,Split:SplitTunnel}" ^
  --output table
```

```cmd
aws ec2 describe-client-vpn-target-networks --region us-east-1 ^
  --client-vpn-endpoint-id cvpn-endpoint-xxxxxxxx ^
  --query "ClientVpnTargetNetworks[*].{Subnet:TargetNetworkId,Status:Status.Code}" --output table
```

Endpoint and target network status should be **available**.

Then continue with **Client setup and connect (local)** below.

---

## Client setup and connect (local)

Mutual TLS: the **laptop** authenticates with a **client** certificate (`client1.crt` + `client1.key`) signed by the same CA you imported as `client_vpn_client_ca_arn`. Terraform/ACM server ARNs are **not** installed on the laptop.

```text
Generate client1 cert → export .ovpn → embed cert/key/CA → AWS VPN Client Connect
  → curl/browser http://<INTERNAL_ALB>/grafana/
```

### 1. Install a VPN client

| Client | Notes |
|---|---|
| **AWS VPN Client** (recommended) | Free desktop app from AWS: https://aws.amazon.com/vpn/client-vpn-download/ |
| OpenVPN Connect / community OpenVPN | Import the same `.ovpn` profile |

### 2. Keep local PKI files ready

From the earlier PKI directory (never commit these):

| File | Used for |
|---|---|
| `client1.crt` | Client identity in `.ovpn` `<cert>` |
| `client1.key` | Client private key in `.ovpn` `<key>` |
| `ca.crt` | CA block in `.ovpn` `<ca>` (if the client requires it) |

Use **client** files, not `server.crt` / `server.key`.

To issue another operator later (same CA):

```cmd
cd /d client-vpn-pki
openssl genrsa -out client2.key 2048
openssl req -new -key client2.key -out client2.csr -subj "/CN=client2"
openssl x509 -req -in client2.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out client2.crt -days 825
```

Each person gets their own `.ovpn` with their own `clientN` cert/key.

### 3. Export the Client VPN configuration (`.ovpn`)

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production output client_vpn_endpoint_id
```

Or:

```cmd
aws ec2 describe-client-vpn-endpoints --region us-east-1 ^
  --query "ClientVpnEndpoints[0].ClientVpnEndpointId" --output text
```

Export (replace the endpoint id):

```cmd
aws ec2 export-client-vpn-client-configuration --region us-east-1 ^
  --client-vpn-endpoint-id cvpn-endpoint-xxxxxxxx ^
  --output text > %USERPROFILE%\Downloads\techx-prod-client-vpn.ovpn
```

PowerShell:

```powershell
aws ec2 export-client-vpn-client-configuration --region us-east-1 `
  --client-vpn-endpoint-id cvpn-endpoint-xxxxxxxx `
  --output text | Set-Content -Encoding ascii "$env:USERPROFILE\Downloads\techx-prod-client-vpn.ovpn"
```

The exported file has `remote`, `remote-random-hostname`, and TLS settings. It does **not** include your client certificate yet.

### 4. Embed client certificate, key, and CA into the `.ovpn`

Open `%USERPROFILE%\Downloads\techx-prod-client-vpn.ovpn` in a text editor. **Append** at the end of the file (full PEM blocks, including `BEGIN`/`END` lines):

```text
<cert>
-----BEGIN CERTIFICATE-----
… entire contents of client1.crt …
-----END CERTIFICATE-----
</cert>

<key>
-----BEGIN PRIVATE KEY-----
… entire contents of client1.key …
-----END PRIVATE KEY-----
</key>

<ca>
-----BEGIN CERTIFICATE-----
… entire contents of ca.crt …
-----END CERTIFICATE-----
</ca>
```

Rules:

* Paste the real PEM text from the files (no extra spaces before `-----BEGIN`).
* Do **not** put the server cert here.
* The client cert must be signed by the CA whose public cert (with key) was imported for `client_vpn_client_ca_arn`.
* Treat the finished `.ovpn` as a **secret** (contains a private key). Do not commit it or share it in chat/tickets.

### 5. Connect with AWS VPN Client

1. Launch **AWS VPN Client**.
2. **File → Manage Profiles → Add Profile**.
3. **Display name:** e.g. `techx-prod`.
4. **VPN configuration file:** browse to `techx-prod-client-vpn.ovpn` (with certs embedded).
5. **Add Profile**.
6. Select the profile → **Connect**.

When connected:

* Status shows **Connected**.
* You receive an IP from the client CIDR (prod `10.100.0.0/22`, e.g. `10.100.0.x`).
* Split tunnel is on: only VPC destinations use the VPN; normal internet stays local.

**OpenVPN Connect alternative:** Import the same `.ovpn` → Connect.

**Disconnect** when finished (connection hours are billed): AWS VPN Client → **Disconnect**.

### 6. Resolve the internal ALB hostname

Admin UIs are on the **internal ALB**, not the CloudFront shop URL.

```cmd
kubectl get ingress frontend-proxy-public -n techx-corp ^
  -o jsonpath="{.status.loadBalancer.ingress[0].hostname}"
```

Or use the live value of `cloudfront_origin_domain_name` in production tfvars (must match current Ingress hostname after ALB recreates).

Example form:

```text
internal-k8s-techxcor-frontend-….us-east-1.elb.amazonaws.com
```

### 7. Open admin paths (while VPN is connected)

Browser:

```text
http://<INTERNAL_ALB_DNS>/
http://<INTERNAL_ALB_DNS>/grafana/
http://<INTERNAL_ALB_DNS>/jaeger/
http://<INTERNAL_ALB_DNS>/loadgen/
http://<INTERNAL_ALB_DNS>/feature/
```

CMD:

```cmd
curl -i http://internal-k8s-….us-east-1.elb.amazonaws.com/
curl -i http://internal-k8s-….us-east-1.elb.amazonaws.com/grafana/
curl -i http://internal-k8s-….us-east-1.elb.amazonaws.com/jaeger/
```

### 8. Dual-path verification

```cmd
REM Public edge — admin still blocked (no VPN required)
curl -i https://shop.hungtran.id.vn/grafana/

REM On VPN — internal ALB full surface
curl -i http://internal-k8s-….us-east-1.elb.amazonaws.com/grafana/
```

| Entry | Expect |
|---|---|
| `https://shop…/grafana/` (CloudFront) | **403** when `cloudfront_block_sensitive_paths=true` |
| `http://<internal-alb>/grafana/` **with VPN connected** | **200** or app login (not edge 403) |
| Same internal ALB URL **without** VPN | Timeout / unreachable from the public internet |

Grafana/Jaeger still use their own credentials (ESO secrets). VPN only provides network access.

### Client connect quick checklist

1. Endpoint + association **available**
2. Export `.ovpn`
3. Append `<cert>` / `<key>` / `<ca>` from **client1** (+ CA)
4. AWS VPN Client → Add Profile → **Connect**
5. Use **internal ALB** DNS for `/grafana`, not the shop hostname
6. Optional: `kubectl get ns` (private API on VPN; public API still works with VPN disconnected)
7. **Disconnect** when done

### Kubernetes API dual-path verify

EKS keeps **both** public and private API access by default in this stack (`endpoint_public_access` and `endpoint_private_access`). Client VPN only adds the **private** path (SG rule).

```cmd
REM With Client VPN Connected (private ENI IPs / VPC DNS):
kubectl get ns

REM Optional: confirm TCP to a private API IP from describe-cluster or earlier timeout
REM Test-NetConnection 10.0.11.5 -Port 443

REM With Client VPN Disconnected (public endpoint):
kubectl get ns
```

Both should succeed when:

* Public endpoint remains enabled (default), and
* Terraform has applied cluster SG ingress TCP **443** from the **Client VPN association security group** (SG-to-SG). A rule that only allows the VPN client CIDR is **not** sufficient for private EKS API ENIs.

---

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| `Certificate ... does not have a domain` on create | Server ACM cert has empty `DomainName` (bare `CN=server`, or CA ARN used as server) | Re-generate **server** leaf with FQDN CN (e.g. `server.clientvpn.techx.local`) + SAN; re-import; set `client_vpn_server_certificate_arn` to the new ARN. Confirm with `describe-certificate` → `DomainName` non-empty. Never use `client_vpn_client_ca_arn` as the server ARN. |
| `Invalid rule description` on ALB SG rule | Non-ASCII chars in rule description (e.g. Unicode arrow) | Module uses ASCII-only descriptions; pull latest `modules/client-vpn` and re-apply |
| VPN connects but ALB times out | ALB SG missing VPN association SG on TCP 80 | Set `client_vpn_alb_security_group_ids` and apply; confirm ingress from Client VPN SG (not only client CIDR). Note: an open `0.0.0.0/0` rule on another ALB SG can mask a missing VPN rule |
| VPN connects but `kubectl` times out to `10.x.x.x:443` | Cluster SG allows only client CIDR, not association SG | Private API needs **SG-to-SG**: Client VPN association SG → cluster SG → TCP 443. Apply module with `eks_cluster_security_group_ids` (env stacks wire `module.eks.cluster_security_group_id`). Client CIDR alone is insufficient |
| `kubectl` works off VPN but not on VPN | Private DNS + private path blocked (above) | On VPN, API hostname resolves to `10.x` ENIs; fix SG-to-SG rule; optional `aws eks update-kubeconfig` |
| Association pending long time | First association cold start | Wait 5–15 minutes; check target network status |
| Auth / TLS handshake fails | Wrong cert in `.ovpn` (server cert used, or client not signed by imported CA) | Re-export; embed **client1** cert/key signed by the CA used for `client_vpn_client_ca_arn` |
| `Certificate does not have key usage extension` / `VERIFY KU ERROR` in AWS VPN Client log | Server leaf missing Key Usage + `serverAuth` EKU (OpenVPN `remote-cert-tls server`) | Re-issue **server** cert with KU/EKU+SAN; re-import ACM; update `client_vpn_server_certificate_arn` and apply. Re-issue client with `clientAuth` and rebuild `.ovpn`. |
| Profile import error | Incomplete PEM blocks or wrong encoding | Re-paste full `BEGIN`/`END` blocks; save `.ovpn` as UTF-8/ASCII without BOM |
| Connects but no route to `10.0.x.x` | Not fully connected, or authorization rule missing | Confirm Connected; check VPC authorization rule exists |
| Overlap error on create | Client CIDR overlaps VPC | Use `10.100.0.0/22` (prod) / `10.101.0.0/22` (dev) |
| Admin still 403 | Hitting CloudFront URL | Use **internal ALB** hostname on VPN, not the shop alias |
| ACM import missing private key | `import-certificate` without `--private-key` | Import `ca.crt` **with** `ca.key` (and server with `server.key`) |

**Do not** set Ingress `alb.ingress.kubernetes.io/inbound-cidrs` to only the VPN client CIDR — that can break CloudFront VPC origin access to the same ALB.

---

## Disable / teardown

```hcl
client_vpn_enabled = false
```

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
```

Revoke operator access by stopping distribution of client certs and rotating the client CA if a key was leaked.

---

## Related

* Edge architecture: [docs/cloudfront.md](./cloudfront.md)
* ADR (why one internal ALB): [docs/adr/storefront-edge-internal-alb.md](./adr/storefront-edge-internal-alb.md)
* Deploy runbook: [docs/DEPLOYMENT.md](./DEPLOYMENT.md)
* Cost: [docs/COST.md](./COST.md)
