# Install Argo CD via official Helm chart (pinned).
# Requires helm + kubernetes providers configured for the target EKS cluster.
#
# Operator UI access (v2): path-based behind the storefront frontend-proxy on the
# internal ALB / private DNS, e.g. https://internal.hungtran.id.vn/argocd
# (VPN only). No public Ingress. CloudFront must block /argocd.

resource "kubernetes_namespace" "argocd" {
  count = var.enabled ? 1 : 0

  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "argocd"
      "app.kubernetes.io/part-of"    = "argocd"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "helm_release" "argocd" {
  count = var.enabled ? 1 : 0

  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.chart_version
  namespace  = kubernetes_namespace.argocd[0].metadata[0].name

  create_namespace = false
  wait             = true
  atomic           = true
  timeout          = var.timeout_seconds

  # ClusterIP only — no public Ingress / storefront ALB exposure of this Service.
  # Path access is via frontend-proxy Envoy (/argocd → this Service) when rootpath is set.
  # Pin control-plane pods to critical MNG (docs/workload-placement.md).
  values = [
    yamlencode({
      global = {
        domain = var.server_domain
        nodeSelector = {
          "workload-class" = "critical"
        }
      }
      configs = {
        params = merge(
          {
            # HTTP behind Envoy/ALB TLS termination (same posture as Grafana on the internal ALB).
            "server.insecure" = tostring(var.server_insecure)
          },
          var.server_rootpath != "" ? {
            "server.basehref" = var.server_rootpath
            "server.rootpath" = var.server_rootpath
          } : {}
        )
        cm = merge(
          {
            "timeout.reconciliation"       = "180s"
            "application.instanceLabelKey" = "argocd.argoproj.io/instance"
          },
          var.server_url != "" ? {
            url = var.server_url
          } : {}
        )
        rbac = {
          "policy.default" = "role:readonly"
          "policy.csv"     = var.rbac_policy_csv
        }
      }
      server = {
        service = {
          type = "ClusterIP"
        }
        ingress = {
          enabled = false
        }
      }
      # Single-replica sufficient for v1; scale HA later.
      controller = {
        replicas = var.controller_replicas
      }
      repoServer = {
        replicas = var.repo_server_replicas
      }
      applicationSet = {
        enabled = var.enable_applicationset
      }
      notifications = {
        enabled = var.enable_notifications
      }
    })
  ]

  depends_on = [kubernetes_namespace.argocd]
}
