#!/usr/bin/env bash
set -euo pipefail

# Bootstrap AWS Secrets Manager AI Observability HMAC secret.
# Usage:
#   ./scripts/bootstrap-ai-observability-secret.sh techx-corp/development [region] [hmac-key]

PREFIX="${1:-}"
REGION="${2:-us-east-1}"
HMAC_KEY="${3:-${AI_OBSERVABILITY_HMAC_KEY:-}}"

if [ -z "${PREFIX}" ]; then
  echo "usage: $0 <name-prefix> [region] [hmac-key]"
  exit 1
fi

if [ -z "${HMAC_KEY}" ]; then
  HMAC_KEY=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p)
fi

KEY_LEN=$(printf '%s' "${HMAC_KEY}" | wc -c)
if [ "${KEY_LEN}" -lt 32 ]; then
  echo "Error: AI_OBSERVABILITY_HMAC_KEY must be at least 32 bytes long" >&2
  exit 1
fi

SECRET_NAME="${PREFIX}/ai-observability"
PAYLOAD=$(jq -n --arg key "${HMAC_KEY}" '{"AI_OBSERVABILITY_HMAC_KEY": $key}')

echo "Writing secret: ${SECRET_NAME} in region ${REGION}..."
aws secretsmanager put-secret-value --secret-id "${SECRET_NAME}" --secret-string "${PAYLOAD}" --region "${REGION}"

# Change trail: @hungxqt - 2026-07-29 - Created shell script for AI Observability secret bootstrap.
