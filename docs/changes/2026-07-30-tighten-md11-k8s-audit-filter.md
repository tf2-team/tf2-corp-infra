# Tighten MD11 K8s audit subscription filter

Production MD11 K8s audit alerts were too noisy because the CloudWatch Logs subscription filter sent broad workload and configuration mutations to the parser. The highest-volume candidates included `secrets watch`, `configmaps update`, and controller/status updates such as `pods/status patch`.

This change overrides the production `high-risk-k8s-events-to-parser` filter to keep only higher-signal candidates:

- Secret `get`, `list`, `delete`, and `deletecollection`.
- RoleBinding and ClusterRoleBinding `create`, `update`, and `patch`.
- Pod `exec`, `attach`, and `portforward` subresources.
- Delete and deletecollection for deployments, statefulsets, daemonsets, services, ingresses, and configmaps.

The filter intentionally removes `secrets watch`, generic pod create/update/patch, workload create/update/patch, status updates, and short-lived job/cronjob lifecycle events from the parser input. Raw EKS audit retention remains covered by the immutable audit pipeline; this change only reduces active MD11 alert candidate noise.

Change trail: @hungxqt - 2026-07-30 - Reduced MD11 K8s active alert noise while preserving high-risk detection signals.
