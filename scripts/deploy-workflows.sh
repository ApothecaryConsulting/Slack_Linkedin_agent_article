#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   bash scripts/deploy-workflows.sh upsert workflow/my-flow.json
#   bash scripts/deploy-workflows.sh delete workflow/my-flow.json
#
# For local use, export N8N_API_URL and N8N_API_KEY before running.

MODE="$1"
FILE="$2"

API_URL="${N8N_API_URL:?N8N_API_URL is required}"
API_KEY="${N8N_API_KEY:?N8N_API_KEY is required}"
AUTH_HEADER="X-N8N-API-KEY: $API_KEY"
CURL_OPTS=(--connect-timeout 10 --max-time 30)

# Call n8n API and print a summary; fail loudly if the response is not JSON
# or does not contain the expected fields.
api_call() {
  local method="$1"; shift
  local url="$1"; shift
  local response http_code

  response=$(curl -s "${CURL_OPTS[@]}" -w '\n__HTTP_STATUS__%{http_code}' "$@" -X "$method" "$url")
  http_code=$(echo "$response" | tail -1 | sed 's/__HTTP_STATUS__//')
  response=$(echo "$response" | sed '$d')

  if ! echo "$response" | jq empty 2>/dev/null; then
    echo "ERROR: n8n returned non-JSON (HTTP $http_code):" >&2
    echo "$response" >&2
    exit 1
  fi

  if [ "$http_code" -ge 400 ]; then
    echo "ERROR: n8n returned HTTP $http_code:" >&2
    echo "$response" | jq . >&2
    exit 1
  fi

  echo "$response" | jq '{id:.id, name:.name}'
}

upsert_workflow() {
  local file="$1"
  local body; body=$(cat "$file")
  local id; id=$(echo "$body" | jq -r '.id // empty')
  local name; name=$(echo "$body" | jq -r '.name')
  local active; active=$(echo "$body" | jq -r '.active')

  if [ -z "$id" ]; then
    echo "ERROR: $file has no .id field" >&2
    exit 1
  fi

  # Check existence by reading the workflow and verifying it's a JSON object
  # with an "id" field — guards against the n8n UI's SPA returning HTTP 200
  # with HTML for any unknown path.
  local existing
  existing=$(curl -s "${CURL_OPTS[@]}" -H "$AUTH_HEADER" "$API_URL/api/v1/workflows/$id")
  local workflow_exists=false
  if echo "$existing" | jq -e '.id' > /dev/null 2>&1; then
    workflow_exists=true
  fi

  if [ "$workflow_exists" = "true" ]; then
    echo "Updating: $name ($id)"
    api_call PUT "$API_URL/api/v1/workflows/$id" \
      -H "Content-Type: application/json" \
      -H "$AUTH_HEADER" \
      -d "$body"
  else
    echo "Creating: $name ($id)"
    api_call POST "$API_URL/api/v1/workflows" \
      -H "Content-Type: application/json" \
      -H "$AUTH_HEADER" \
      -d "$body"
  fi

  if [ "$active" = "true" ]; then
    echo "Activating: $name"
    curl -s "${CURL_OPTS[@]}" -X POST -H "$AUTH_HEADER" "$API_URL/api/v1/workflows/$id/activate" > /dev/null
  else
    curl -s "${CURL_OPTS[@]}" -X POST -H "$AUTH_HEADER" "$API_URL/api/v1/workflows/$id/deactivate" > /dev/null
  fi
}

delete_workflow() {
  local file="$1"
  local body; body=$(git show HEAD~1:"$file" 2>/dev/null || true)

  if [ -z "$body" ]; then
    echo "WARNING: could not recover $file from git history — skipping delete" >&2
    return
  fi

  local id; id=$(echo "$body" | jq -r '.id // empty')
  local name; name=$(echo "$body" | jq -r '.name')

  if [ -z "$id" ]; then
    echo "WARNING: no .id in recovered $file — skipping delete" >&2
    return
  fi

  echo "Deleting: $name ($id)"
  curl -s "${CURL_OPTS[@]}" -X DELETE \
    -H "$AUTH_HEADER" \
    "$API_URL/api/v1/workflows/$id"
}

case "$MODE" in
  upsert) upsert_workflow "$FILE" ;;
  delete) delete_workflow "$FILE" ;;
  *) echo "Usage: $0 <upsert|delete> <workflow-file>" >&2; exit 1 ;;
esac
