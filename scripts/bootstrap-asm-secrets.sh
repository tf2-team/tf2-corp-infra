#!/usr/bin/env bash
# Bootstrap AWS Secrets Manager values for SEC-05 cutover.
# Writes CURRENT live credentials only — do not invent new DB passwords here.
# Values never go through Terraform.
#
# Usage (bash / Git Bash / WSL):
#   ./scripts/bootstrap-asm-secrets.sh techx-corp/development us-east-1
#   ./scripts/bootstrap-asm-secrets.sh techx-corp/production us-east-1
#
# Windows CMD equivalent:
#   scripts\bootstrap-asm-secrets.cmd techx-corp/development us-east-1
#
# Override defaults via env:
#   PG_ADMIN_USER PG_ADMIN_PASSWORD PG_ADMIN_DB
#   PG_APP_USER PG_APP_PASSWORD PG_APP_DB
#   SECRET_KEY_BASE OPENAI_API_KEY GRAFANA_USER GRAFANA_PASSWORD

set -euo pipefail

PREFIX="${1:?usage: $0 <name-prefix> [region]}"
REGION="${2:-us-east-1}"

PG_ADMIN_USER="${PG_ADMIN_USER:-root}"
PG_ADMIN_PASSWORD="${PG_ADMIN_PASSWORD:-otel}"
PG_ADMIN_DB="${PG_ADMIN_DB:-otel}"

PG_APP_USER="${PG_APP_USER:-otelu}"
PG_APP_PASSWORD="${PG_APP_PASSWORD:-otelp}"
PG_APP_DB="${PG_APP_DB:-otel}"

SECRET_KEY_BASE="${SECRET_KEY_BASE:-yYrECL4qbNwleYInGJYvVnSkwJuSQJ4ijPTx5tirGUXrbznFIBFVJdPl5t6O9ASw}"
OPENAI_API_KEY="${OPENAI_API_KEY:-dummy}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"

# SEC-06: OpenSearch security plugin credentials
# Override: OPENSEARCH_ADMIN_USER, OPENSEARCH_ADMIN_PASSWORD
# Password MUST be alphanumeric length >= 24 (OpenSearch requirement).
OPENSEARCH_ADMIN_USER="${OPENSEARCH_ADMIN_USER:-admin}"
OPENSEARCH_ADMIN_PASSWORD="${OPENSEARCH_ADMIN_PASSWORD:-ChangeMe000000000000000000}"

put_json() {
  local name="$1"
  local json="$2"
  echo "Putting secret: ${name}"
  aws secretsmanager put-secret-value \
    --region "${REGION}" \
    --secret-id "${name}" \
    --secret-string "${json}" >/dev/null
}

put_json "${PREFIX}/postgresql-admin" \
  "{\"username\":\"${PG_ADMIN_USER}\",\"password\":\"${PG_ADMIN_PASSWORD}\",\"database\":\"${PG_ADMIN_DB}\"}"

put_json "${PREFIX}/postgresql-app" \
  "{\"username\":\"${PG_APP_USER}\",\"password\":\"${PG_APP_PASSWORD}\",\"database\":\"${PG_APP_DB}\"}"

put_json "${PREFIX}/flagd-ui" \
  "{\"SECRET_KEY_BASE\":\"${SECRET_KEY_BASE}\"}"

put_json "${PREFIX}/product-reviews" \
  "{\"OPENAI_API_KEY\":\"${OPENAI_API_KEY}\"}"

put_json "${PREFIX}/grafana" \
  "{\"admin-user\":\"${GRAFANA_USER}\",\"admin-password\":\"${GRAFANA_PASSWORD}\"}"

# SEC-06: OpenSearch security plugin admin credentials
put_json "${PREFIX}/opensearch" \
  "{\"username\":\"${OPENSEARCH_ADMIN_USER}\",\"password\":\"${OPENSEARCH_ADMIN_PASSWORD}\"}"

# Grafana Discord alert webhook
# Override: DISCORD_WEBHOOK_URL
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
if [ -n "${DISCORD_WEBHOOK_URL}" ]; then
  put_json "${PREFIX}/grafana-discord" \
    "{\"webhook-url\":\"${DISCORD_WEBHOOK_URL}\"}"
fi

echo "Done. Bootstrap complete for prefix=${PREFIX} region=${REGION}"
echo "Next: install ESO + ClusterSecretStore, then helm techx-corp-secrets, wait Ready, then app chart."
