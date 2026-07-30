#!/usr/bin/env bash
set -euo pipefail

# Bootstrap AWS Secrets Manager AIOps live executor secret.
# Preserves the existing token when present and only adds/updates approval_id.
# Usage:
#   ./scripts/bootstrap-aiops-live-executor-secret.sh techx-corp/production us-east-1 adr-live-001

PREFIX="${1:-}"
REGION="${2:-us-east-1}"
APPROVAL_ID="${3:-${AIOPS_LIVE_EXECUTOR_APPROVAL_ID:-}}"
TOKEN="${4:-${AIOPS_LIVE_EXECUTOR_TOKEN:-}}"

if [ -z "${PREFIX}" ]; then
  echo "usage: $0 <name-prefix> [region] <approval-id> [token]" >&2
  exit 1
fi

if [ -z "${APPROVAL_ID}" ]; then
  echo "Error: approval-id is required. Pass it as arg 3 or AIOPS_LIVE_EXECUTOR_APPROVAL_ID." >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "Error: AWS CLI not found on PATH." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq not found on PATH." >&2
  exit 1
fi

SECRET_NAME="${PREFIX}/aiops-live-executor-token"

if [ -z "${TOKEN}" ]; then
  EXISTING_SECRET=$(
    aws secretsmanager get-secret-value \
      --region "${REGION}" \
      --secret-id "${SECRET_NAME}" \
      --query SecretString \
      --output text 2>/dev/null || true
  )

  if [ -n "${EXISTING_SECRET}" ] && [ "${EXISTING_SECRET}" != "None" ]; then
    TOKEN=$(printf '%s' "${EXISTING_SECRET}" | jq -r '.token // empty' 2>/dev/null || true)
  fi
fi

if [ -z "${TOKEN}" ]; then
  TOKEN=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p)
  echo "Generated new executor token because no existing token was found."
else
  echo "Preserving existing executor token."
fi

PAYLOAD=$(jq -n \
  --arg token "${TOKEN}" \
  --arg approval_id "${APPROVAL_ID}" \
  '{"token": $token, "approval_id": $approval_id}')

TMP_FILE=$(mktemp)
trap 'rm -f "${TMP_FILE}"' EXIT
printf '%s' "${PAYLOAD}" >"${TMP_FILE}"

echo "Writing secret: ${SECRET_NAME} in region ${REGION}..."
aws secretsmanager put-secret-value \
  --region "${REGION}" \
  --secret-id "${SECRET_NAME}" \
  --secret-string "file://${TMP_FILE}" >/dev/null

echo "Done. AIOps live executor secret now contains token and approval_id."

# Change trail: @hungxqt - 2026-07-29 - Add AIOps live executor approval bootstrap.
