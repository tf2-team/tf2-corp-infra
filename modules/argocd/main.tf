# Install Argo CD via official Helm chart (pinned).
# Requires helm + kubernetes providers configured for the target EKS cluster.

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

  # v1: ClusterIP only — no public Ingress / storefront ALB exposure.
  values = [
    yamlencode({
      global = {
        domain = var.server_domain
      }
      configs = {
        params = {
          # Keep TLS on server; access via port-forward or future private ALB.
          "server.insecure" = false
        }
        cm = {
          "timeout.reconciliation" = "180s"
          "application.instanceLabelKey" = "argocd.argoproj.io/instance"
        }
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
