#!/usr/bin/env bash
# Render a safe structural Markdown summary from terraform show -json output.
# Usage: terraform show -json tfplan | render-terraform-plan-summary.sh <environment>
# Never prints attribute values, outputs, provider configuration, or raw plan JSON.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <environment>" >&2
  exit 2
fi

ENVIRONMENT="$1"
MAX_ADDRESSES=200

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

# Escape for use inside Markdown inline code spans and HTML comments.
escape_address() {
  local s=$1
  # Strip characters that could break out of inline code or inject HTML.
  s=${s//\`/\'}
  s=${s//</(}
  s=${s//>/(}
  printf '%s' "$s"
}

PLAN_JSON=$(cat)

if ! echo "$PLAN_JSON" | jq -e . >/dev/null 2>&1; then
  echo "error: stdin is not valid JSON" >&2
  exit 1
fi

# Classify resource_changes. Skip no-op and read-only.
# replace: both create and delete; add/delete/change otherwise.
mapfile -t ROWS < <(echo "$PLAN_JSON" | jq -r '
  (.resource_changes // [])[]
  | . as $rc
  | ($rc.change.actions // []) as $actions
  | if ($actions | index("no-op")) then empty
    elif ($actions == ["read"]) then empty
    else
      (($actions | index("create")) != null) as $has_create
      | (($actions | index("delete")) != null) as $has_delete
      | (($actions | index("update")) != null) as $has_update
      | if ($has_create and $has_delete) then "replace\t\($rc.address)"
        elif $has_create then "add\t\($rc.address)"
        elif $has_delete then "delete\t\($rc.address)"
        elif $has_update then "change\t\($rc.address)"
        else empty
        end
    end
')

ADD=0
CHANGE=0
DELETE=0
REPLACE=0
ADDRESSES=()

if ((${#ROWS[@]} > 0)); then
  for row in "${ROWS[@]}"; do
    [[ -z "${row:-}" ]] && continue
    kind=${row%%$'\t'*}
    addr=${row#*$'\t'}
    case "$kind" in
      add) ADD=$((ADD + 1)) ;;
      change) CHANGE=$((CHANGE + 1)) ;;
      delete) DELETE=$((DELETE + 1)) ;;
      replace) REPLACE=$((REPLACE + 1)) ;;
    esac
    ADDRESSES+=("$addr")
  done
fi

TOTAL=${#ADDRESSES[@]}
TRUNCATED=0
if (( TOTAL > MAX_ADDRESSES )); then
  TRUNCATED=$((TOTAL - MAX_ADDRESSES))
  ADDRESSES=("${ADDRESSES[@]:0:MAX_ADDRESSES}")
fi

{
  echo "### Terraform plan summary: \`${ENVIRONMENT}\`"
  echo
  echo "| Action | Count |"
  echo "| --- | ---: |"
  echo "| Add | ${ADD} |"
  echo "| Change | ${CHANGE} |"
  echo "| Delete | ${DELETE} |"
  echo "| Replace | ${REPLACE} |"
  echo
  echo "**Total resource changes:** ${TOTAL}"
  echo
  if (( TOTAL == 0 )); then
    echo "_No resource changes._"
  else
    echo "#### Resource addresses"
    echo
    for addr in "${ADDRESSES[@]}"; do
      escaped=$(escape_address "$addr")
      echo "- \`${escaped}\`"
    done
    if (( TRUNCATED > 0 )); then
      echo
      echo "_…and ${TRUNCATED} more address(es) omitted (cap ${MAX_ADDRESSES})._"
    fi
  fi
  echo
  echo "<!-- safe-plan-summary: no attribute values, outputs, or raw plan JSON -->"
}
