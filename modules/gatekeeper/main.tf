resource "kubernetes_namespace" "gatekeeper" {
  count = var.enabled ? 1 : 0

  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "gatekeeper"
      "app.kubernetes.io/part-of"    = "gatekeeper"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "helm_release" "gatekeeper" {
  count = var.enabled ? 1 : 0

  name       = "gatekeeper"
  repository = "https://open-policy-agent.github.io/gatekeeper/charts"
  chart      = "gatekeeper"
  version    = var.chart_version
  namespace  = kubernetes_namespace.gatekeeper[0].metadata[0].name

  create_namespace = false
  wait             = true
  atomic           = true
  timeout          = var.timeout_seconds

  values = [
    yamlencode({
      replicas                         = var.controller_replicas
      auditInterval                    = 60
      auditMatchKindOnly               = true
      constraintViolationsLimit        = 100
      metricsBackends                  = ["prometheus"]
      validatingWebhookFailurePolicy   = "Fail"
      enableExternalData               = false
      disableMutation                  = true
      enableGeneratorResourceExpansion = false

      pdb = {
        controllerManager = {
          minAvailable = 1
        }
      }

      controllerManager = {
        nodeSelector = {
          "kubernetes.io/os" = "linux"
          "workload-class"   = "critical"
        }
        resources = {
          requests = {
            cpu    = "100m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
      }

      audit = {
        nodeSelector = {
          "kubernetes.io/os" = "linux"
          "workload-class"   = "critical"
        }
        resources = {
          requests = {
            cpu    = "100m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.gatekeeper]
}
