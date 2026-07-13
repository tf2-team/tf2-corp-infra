# AWS Client VPN — private admin access to the internal storefront ALB

Client VPN lets operators reach the **existing internal** storefront ALB (Ingress `frontend-proxy-public`) so they can open admin/observability paths that CloudFront blocks for the public internet.

```
Browser (public HTTPS)
    → CloudFront (path 403: /grafana, /jaeger, …)
        → VPC origin → Internal ALB → frontend-proxy

Operator laptop
    → AWS Client VPN (mutual TLS, split tunnel)
        → Internal ALB (same ALB; all paths open) → frontend-proxy
```

| Entry | Storefront | Admin paths |
|---|---|---|
| CloudFront alias | Allowed | **403** when `cloudfront_block_sensitive_paths=true` |
| Internet → internal ALB | Not reachable (private) | Not reachable |
| Client VPN → internal ALB DNS | Allowed | **Allowed** (Grafana/Jaeger app auth still applies) |

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

## Prerequisites

1. **Internal storefront ALB healthy** — chart `values-public-alb.yaml` (`scheme: internal`, `blockSensitivePaths: false`).
2. **ACM certificates in the VPC region** (`us-east-1` for this stack):
   - Server certificate for the Client VPN endpoint  
   - Client CA certificate (root/intermediate that signs user client certs)
3. Optional but recommended: **ALB security group ID** so Terraform can open TCP 80 from the VPN client CIDR without touching Ingress annotations (avoids fighting CloudFront VPC-origin SG automation).

Terraform does **not** generate private keys or ACM certificates.

---

## Inputs

| Variable | Required when enabled | Description |
|---|---|---|
| `client_vpn_enabled` | — | Gate; default `false` |
| `client_vpn_server_certificate_arn` | Yes | ACM server cert ARN (same region as VPC) |
| `client_vpn_client_ca_arn` | Yes | ACM client CA cert ARN |
| `client_vpn_client_cidr_block` | No | Prod default `10.100.0.0/22`; dev `10.101.0.0/22` (must **not** overlap VPC) |
| `client_vpn_subnet_ids` | No | Empty = first private subnet only |
| `client_vpn_split_tunnel` | No | Default `true` |
| `client_vpn_alb_security_group_ids` | Recommended | Internal ALB SG(s); adds ingress TCP 80 from client CIDR |

---

## Certificate generation (operator-owned PKI)

Generate a small CA, a server cert, and at least one client cert **outside the repo**. Never commit private keys.

Example with OpenSSL (adjust subject SANs as needed):

```cmd
mkdir client-vpn-pki && cd client-vpn-pki

REM CA
openssl genrsa -out ca.key 2048
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt -subj "/CN=TechX Client VPN CA"

REM Server
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=server"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 825

REM Client (one per operator; revoke by not redistributing)
openssl genrsa -out client1.key 2048
openssl req -new -key client1.key -out client1.csr -subj "/CN=client1"
openssl x509 -req -in client1.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out client1.crt -days 825
```

Import into ACM (`us-east-1`):

```cmd
aws acm import-certificate --region us-east-1 ^
  --certificate fileb://server.crt ^
  --private-key fileb://server.key ^
  --certificate-chain fileb://ca.crt

aws acm import-certificate --region us-east-1 ^
  --certificate fileb://ca.crt
```

Use the returned ARNs as `client_vpn_server_certificate_arn` and `client_vpn_client_ca_arn`.

> Server cert must be the leaf+key (+ chain). Client CA import is the CA certificate only (no private key required for ACM CA import used as `root_certificate_chain_arn`).

---

## Discover internal ALB security group

```cmd
REM From ALB DNS (same as cloudfront_origin_domain_name)
aws elbv2 describe-load-balancers --region us-east-1 ^
  --query "LoadBalancers[?DNSName=='k8s-….elb.amazonaws.com'].SecurityGroups" --output text
```

Or from the load balancer ARN:

```cmd
aws elbv2 describe-load-balancers --region us-east-1 ^
  --load-balancer-arns arn:aws:elasticloadbalancing:… ^
  --query "LoadBalancers[0].SecurityGroups" --output text
```

---

## Enable sequence

### 1. Set tfvars

**Production example:**

```hcl
client_vpn_enabled                = true
client_vpn_client_cidr_block      = "10.100.0.0/22"
client_vpn_server_certificate_arn = "arn:aws:acm:us-east-1:ACCOUNT:certificate/SERVER-ID"
client_vpn_client_ca_arn          = "arn:aws:acm:us-east-1:ACCOUNT:certificate/CA-ID"
client_vpn_alb_security_group_ids = ["sg-xxxxxxxx"]
```

**Development** uses `10.101.0.0/22` (VPC is `10.1.0.0/16`).

### 2. Apply

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
terraform -chdir=environments/production output client_vpn_endpoint_id
terraform -chdir=environments/production output client_vpn_export_client_config_command
```

Association can take several minutes to become available.

### 3. Export client configuration

```cmd
aws ec2 export-client-vpn-client-configuration --region us-east-1 ^
  --client-vpn-endpoint-id cvpn-endpoint-xxxxxxxx ^
  --output text > client-vpn.ovpn
```

Edit `client-vpn.ovpn` and append the client certificate and key:

```text
<cert>
… contents of client1.crt …
</cert>
<key>
… contents of client1.key …
</key>
```

Some clients also need the CA:

```text
<ca>
… contents of ca.crt …
</ca>
```

Import into **AWS VPN Client** or OpenVPN Connect and connect.

### 4. Resolve internal ALB hostname

```cmd
kubectl get ingress frontend-proxy-public -n techx-corp ^
  -o jsonpath="{.status.loadBalancer.ingress[0].hostname}"
```

Or use `cloudfront_origin_domain_name` from production tfvars / Terraform output.

### 5. Verify dual path

```cmd
REM Public edge — admin still blocked
curl -i https://shop.hungtran.id.vn/grafana/

REM On VPN — internal ALB full surface
curl -i http://k8s-techxcor-frontend-….us-east-1.elb.amazonaws.com/
curl -i http://k8s-techxcor-frontend-….us-east-1.elb.amazonaws.com/grafana/
curl -i http://k8s-techxcor-frontend-….us-east-1.elb.amazonaws.com/jaeger/
```

Expect:

* CloudFront `/grafana` → **403**  
* Internal ALB `/grafana` while VPN connected → **200** or app login (not edge 403)

---

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| VPN connects but ALB times out | ALB SG missing client CIDR | Set `client_vpn_alb_security_group_ids` or add TCP 80 from client CIDR manually |
| Association pending long time | First association cold start | Wait 5–15 minutes; check subnet has free IPs |
| Auth failure | Client cert not signed by imported CA | Re-issue client cert; re-import CA if wrong cert |
| Overlap error on create | Client CIDR overlaps VPC | Use `10.100.0.0/22` (prod) / `10.101.0.0/22` (dev) |
| Admin still 403 | Hitting CloudFront URL | Use **internal ALB** hostname, not the shop alias |

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
