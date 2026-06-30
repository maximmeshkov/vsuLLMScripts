#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ENV_FILE="${ENV_FILE:-.env}"
if [[ -f "$ENV_FILE" ]]; then
  sed -i 's/\r$//' "$ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

IMAGE_RAG_PORT="${IMAGE_RAG_PORT:-8010}"
IMAGE_RAG_API_KEY="${IMAGE_RAG_API_KEY:-}"
base_url="http://127.0.0.1:${IMAGE_RAG_PORT}"

auth_args=()
if [[ -n "$IMAGE_RAG_API_KEY" ]]; then
  auth_args=(-H "Authorization: Bearer ${IMAGE_RAG_API_KEY}")
fi

action="${1:-health}"
shift || true

case "$action" in
  health)
    curl -sS "${auth_args[@]}" "${base_url}/health"
    echo
    ;;
  index)
    force=false
    if [[ "${1:-}" == "--force" ]]; then
      force=true
    fi
    curl -sS "${auth_args[@]}" -H "Content-Type: application/json" \
      -d "{\"force\":${force}}" \
      "${base_url}/index"
    echo
    ;;
  search)
    query="${1:?search requires query}"
    limit="${2:-5}"
    escaped_query="${query//\\/\\\\}"
    escaped_query="${escaped_query//\"/\\\"}"
    escaped_query="${escaped_query//$'\n'/ }"
    payload="{\"query\":\"${escaped_query}\",\"limit\":${limit}}"
    curl -sS "${auth_args[@]}" -H "Content-Type: application/json" \
      -d "$payload" \
      "${base_url}/search"
    echo
    ;;
  *)
    echo "Usage: ./image_rag.sh health | index [--force] | search QUERY [LIMIT]" >&2
    exit 2
    ;;
esac
