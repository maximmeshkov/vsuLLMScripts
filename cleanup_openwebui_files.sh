#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

MODE="failed"
KEEP_KNOWLEDGE_ID=""
KEEP_KNOWLEDGE_NAME=""
APPLY=false
YES=false

usage() {
  cat <<'USAGE'
Usage:
  ./cleanup_openwebui_files.sh [options]

Default is dry-run. Nothing is deleted unless both --apply and --yes are passed.

Modes:
  --failed
      Delete only files with data.status=failed. This is the default.

  --orphaned
      Delete files that are not linked to any Knowledge base.

  --not-in-knowledge ID
      Delete every file that is not linked to Knowledge ID.

  --not-in-knowledge-name NAME
      Delete every file that is not linked to the first Knowledge base with this name.

Options:
  --apply
      Perform deletion through Open WebUI DELETE /api/v1/files/{id}.

  --yes
      Required together with --apply.

Examples:
  ./cleanup_openwebui_files.sh
  ./cleanup_openwebui_files.sh --failed --apply --yes
  ./cleanup_openwebui_files.sh --not-in-knowledge-name rfBooks
  ./cleanup_openwebui_files.sh --not-in-knowledge-name rfBooks --apply --yes
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --failed)
      MODE="failed"
      ;;
    --orphaned)
      MODE="orphaned"
      ;;
    --not-in-knowledge)
      MODE="not-in-knowledge"
      KEEP_KNOWLEDGE_ID="${2:-}"
      shift
      ;;
    --not-in-knowledge-name)
      MODE="not-in-knowledge-name"
      KEEP_KNOWLEDGE_NAME="${2:-}"
      shift
      ;;
    --apply)
      APPLY=true
      ;;
    --yes)
      YES=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "$MODE" == "not-in-knowledge" && -z "$KEEP_KNOWLEDGE_ID" ]]; then
  echo "--not-in-knowledge requires a Knowledge ID" >&2
  exit 2
fi

if [[ "$MODE" == "not-in-knowledge-name" && -z "$KEEP_KNOWLEDGE_NAME" ]]; then
  echo "--not-in-knowledge-name requires a Knowledge name" >&2
  exit 2
fi

if [[ "$APPLY" == true && "$YES" != true ]]; then
  echo "Refusing to delete without --yes. Re-run with --apply --yes." >&2
  exit 2
fi

if ! docker compose --env-file .env ps open-webui >/dev/null 2>&1; then
  echo "open-webui container is not available. Start the stack first." >&2
  exit 1
fi

if [[ "$MODE" == "not-in-knowledge-name" ]]; then
  KEEP_KNOWLEDGE_ID="$(
    docker exec -i open-webui python - "$KEEP_KNOWLEDGE_NAME" <<'PY'
import sqlite3
import sys

name = sys.argv[1]
con = sqlite3.connect("/app/backend/data/webui.db")
row = con.execute(
    "select id from knowledge where name=? order by created_at desc limit 1",
    (name,),
).fetchone()
if not row:
    raise SystemExit(f"Knowledge not found: {name}")
print(row[0])
PY
  )"
fi

echo "Open WebUI file cleanup"
echo "Mode: $MODE"
if [[ -n "$KEEP_KNOWLEDGE_ID" ]]; then
  echo "Keep Knowledge ID: $KEEP_KNOWLEDGE_ID"
fi
if [[ "$APPLY" == true ]]; then
  echo "Action: DELETE"
else
  echo "Action: DRY-RUN"
fi
echo

candidate_file="$(mktemp)"
trap 'rm -f "$candidate_file"' EXIT

docker exec -i open-webui python - "$MODE" "$KEEP_KNOWLEDGE_ID" <<'PY' > "$candidate_file"
import json
import sqlite3
import sys

mode = sys.argv[1]
keep_knowledge_id = sys.argv[2] or None

con = sqlite3.connect("/app/backend/data/webui.db")
con.row_factory = sqlite3.Row

links = {}
for row in con.execute("select knowledge_id, file_id from knowledge_file"):
    links.setdefault(row["file_id"], set()).add(row["knowledge_id"])

rows = con.execute(
    "select id, filename, data, meta, path from file order by created_at"
).fetchall()

for row in rows:
    data = json.loads(row["data"]) if row["data"] else {}
    meta = json.loads(row["meta"]) if row["meta"] else {}
    file_links = sorted(links.get(row["id"], set()))
    status = data.get("status") or ""
    indexed = bool(meta.get("collection_name"))

    delete = False
    reason = ""
    if mode == "failed":
        delete = status == "failed"
        reason = "failed"
    elif mode == "orphaned":
        delete = not file_links
        reason = "not linked to any knowledge"
    elif mode in ("not-in-knowledge", "not-in-knowledge-name"):
        delete = keep_knowledge_id not in file_links
        reason = f"not linked to knowledge {keep_knowledge_id}"
    else:
        raise SystemExit(f"Unsupported mode: {mode}")

    if delete:
        print(
            "\t".join(
                [
                    row["id"],
                    status,
                    "indexed" if indexed else "not_indexed",
                    ",".join(file_links) if file_links else "-",
                    reason,
                    row["filename"],
                ]
            )
        )
PY

count="$(wc -l < "$candidate_file" | tr -d ' ')"
if [[ "$count" == "0" ]]; then
  echo "No candidates."
  exit 0
fi

printf 'Candidates: %s\n\n' "$count"
awk -F '\t' '{ printf "  - %s | %s | %s | links=%s | %s\n      %s\n", $1, $2, $3, $4, $5, $6 }' "$candidate_file"
echo

if [[ "$APPLY" != true ]]; then
  echo "Dry-run only. Add --apply --yes to delete these files through Open WebUI API."
  exit 0
fi

admin_id="$(
  docker exec -i open-webui python - <<'PY'
import sqlite3

con = sqlite3.connect("/app/backend/data/webui.db")
row = con.execute(
    "select id from user where role='admin' order by created_at limit 1"
).fetchone()
if not row:
    raise SystemExit("No admin user found")
print(row[0])
PY
)"

token="$(
  docker exec open-webui python -c \
    "from open_webui.utils.auth import create_token; print(create_token({'id':'$admin_id'}))" \
    2>/dev/null | tail -n 1
)"

while IFS=$'\t' read -r file_id _status _indexed _links _reason filename; do
  printf 'Deleting %s  %s\n' "$file_id" "$filename"
  curl -fsS -X DELETE \
    -H "Authorization: Bearer $token" \
    "http://127.0.0.1:${WEBUI_PORT:-3000}/api/v1/files/$file_id" >/dev/null
done < "$candidate_file"

echo
echo "Cleanup finished."
