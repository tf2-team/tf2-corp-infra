#!/usr/bin/env bash
# Fixture tests for scripts/render-terraform-plan-summary.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="${ROOT}/scripts/render-terraform-plan-summary.sh"
FIXTURES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures"
FAILED=0

run_case() {
  local name=$1
  local fixture=$2
  shift 2
  local out
  out=$(bash "$SCRIPT" "testenv" <"$fixture")
  local secret
  for secret in \
    SHOULD_NEVER_APPEAR_NOOP \
    SHOULD_NEVER_APPEAR_OUTPUT \
    SHOULD_NEVER_APPEAR_CREATE \
    SHOULD_NEVER_APPEAR_UPDATE_BEFORE \
    SHOULD_NEVER_APPEAR_UPDATE_AFTER \
    SHOULD_NEVER_APPEAR_DELETE \
    SHOULD_NEVER_APPEAR_REPLACE_BEFORE \
    SHOULD_NEVER_APPEAR_REPLACE_AFTER \
    SHOULD_NEVER_APPEAR_ESCAPE \
    ami-SECRETCREATE
  do
    if grep -Fq "$secret" <<<"$out"; then
      echo "FAIL $name: leaked secret marker: $secret" >&2
      FAILED=1
      return
    fi
  done
  # Must not dump raw JSON keys that indicate full plan payload
  if grep -Eq '"before"|"after"|"output_changes"' <<<"$out"; then
    echo "FAIL $name: raw plan JSON fragments present" >&2
    FAILED=1
    return
  fi
  local expect
  for expect in "$@"; do
    if ! grep -Fq "$expect" <<<"$out"; then
      echo "FAIL $name: missing expected: $expect" >&2
      echo "$out" >&2
      FAILED=1
      return
    fi
  done
  echo "PASS $name"
}

run_case "noop" "$FIXTURES/noop.json" \
  "| Add | 0 |" "| Change | 0 |" "| Delete | 0 |" "| Replace | 0 |" \
  "No resource changes"

run_case "create" "$FIXTURES/create.json" \
  "| Add | 1 |" "aws_instance.app"

run_case "update" "$FIXTURES/update.json" \
  "| Change | 1 |" "aws_security_group.web"

run_case "delete" "$FIXTURES/delete.json" \
  "| Delete | 1 |" "aws_eip.old"

run_case "replace" "$FIXTURES/replace.json" \
  "| Replace | 1 |" "aws_db_instance.main"

# Escaping: backticks in address must not appear unescaped as code breakers;
# secret attribute must never appear. Address body should still be recognizable.
run_case "escape" "$FIXTURES/escape.json" \
  "| Add | 1 |" "module.x.aws_iam_role.r"

# Cap at 200 addresses
CAP_JSON=$(mktemp)
{
  echo '{"format_version":"1.2","resource_changes":['
  for i in $(seq 1 205); do
    [[ $i -gt 1 ]] && echo ','
    printf '{"address":"aws_s3_bucket.b_%s","change":{"actions":["create"],"before":null,"after":{"x":"SHOULD_NEVER_APPEAR_CAP_%s"}}}' "$i" "$i"
  done
  echo ']}'
} >"$CAP_JSON"

CAP_OUT=$(bash "$SCRIPT" "testenv" <"$CAP_JSON")
rm -f "$CAP_JSON"

if grep -Fq "SHOULD_NEVER_APPEAR_CAP" <<<"$CAP_OUT"; then
  echo "FAIL cap: leaked cap fixture attributes" >&2
  FAILED=1
elif ! grep -Fq "**Total resource changes:** 205" <<<"$CAP_OUT"; then
  echo "FAIL cap: wrong total" >&2
  echo "$CAP_OUT" >&2
  FAILED=1
elif ! grep -Fq "more address(es) omitted (cap 200)" <<<"$CAP_OUT"; then
  echo "FAIL cap: missing truncation notice" >&2
  FAILED=1
elif [[ $(grep -c '^\- `' <<<"$CAP_OUT") -ne 200 ]]; then
  echo "FAIL cap: expected 200 address lines, got $(grep -c '^\- `' <<<"$CAP_OUT")" >&2
  FAILED=1
else
  echo "PASS cap"
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo "Some tests failed" >&2
  exit 1
fi
echo "All render-terraform-plan-summary tests passed"
