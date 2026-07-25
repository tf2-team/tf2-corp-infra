resource "kubernetes_network_policy_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = var.name
      }
    }

    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = var.vpc_cidr_block
        }
      }

      ports {
        protocol = "TCP"
        port     = "9096"
      }
    }
  }
}

resource "kubernetes_job_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"       = var.name
      "app.kubernetes.io/component"  = "kafka-topic-bootstrap"
      "app.kubernetes.io/managed-by" = "Terraform"
    }
  }

  spec {
    backoff_limit              = 3
    active_deadline_seconds    = 300
    ttl_seconds_after_finished = null

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = var.name
          "app.kubernetes.io/component" = "kafka-topic-bootstrap"
        }
      }

      spec {
        automount_service_account_token = false
        restart_policy                  = "OnFailure"

        security_context {
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name    = "create-topic"
          image   = var.image
          command = ["/bin/bash", "-ec"]
          args = [<<-EOT
            umask 077
            cat > /tmp/client.properties <<EOF
            security.protocol=SASL_SSL
            sasl.mechanism=SCRAM-SHA-512
            sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="$${KAFKA_SASL_USERNAME}" password="$${KAFKA_SASL_PASSWORD}";
            EOF
            /opt/kafka/bin/kafka-topics.sh \
              --bootstrap-server "$${KAFKA_ADDR}" \
              --command-config /tmp/client.properties \
              --create --if-not-exists \
              --topic "${var.topic_name}" \
              --partitions ${var.partitions} \
              --replication-factor ${var.replication_factor}
            /opt/kafka/bin/kafka-topics.sh \
              --bootstrap-server "$${KAFKA_ADDR}" \
              --command-config /tmp/client.properties \
              --describe --topic "${var.topic_name}"
          EOT
          ]

          env {
            name = "KAFKA_ADDR"
            value_from {
              secret_key_ref {
                name = var.secret_name
                key  = "KAFKA_ADDR"
              }
            }
          }

          env {
            name = "KAFKA_SASL_USERNAME"
            value_from {
              secret_key_ref {
                name = var.secret_name
                key  = "KAFKA_SASL_USERNAME"
              }
            }
          }

          env {
            name = "KAFKA_SASL_PASSWORD"
            value_from {
              secret_key_ref {
                name = var.secret_name
                key  = "KAFKA_SASL_PASSWORD"
              }
            }
          }

          resources {
            requests = {
              cpu    = "25m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 1000
            run_as_group               = 1000

            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
  }

  depends_on = [kubernetes_network_policy_v1.this]
}
