#!/usr/bin/env bash
set -euo pipefail

# start-all.sh - server-like Linux/WSL startup path.
# Run inside WSL Ubuntu or Linux server with Docker Engine, not through Docker Desktop.

NO_BUILD=false
SKIP_GPU_TEST=false
SKIP_FUNCTIONAL=false
ENV_FILE=".env"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) NO_BUILD=true ;;
    --skip-gpu-test) SKIP_GPU_TEST=true ;;
    --skip-functional) SKIP_FUNCTIONAL=true ;;
    --env-file) ENV_FILE="$2"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

cd "$(dirname "${BASH_SOURCE[0]}")"

new_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr '+/' '-_' | tr -d '='
  else
    head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '='
  fi
}

ensure_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    return
  fi
  if [[ ! -f .env.example ]]; then
    echo "Missing .env and .env.example" >&2
    exit 1
  fi
  cp .env.example "$ENV_FILE"
  local webui_secret mcpo_secret
  webui_secret="$(new_secret)"
  mcpo_secret="$(new_secret)"
  sed -i "s|WEBUI_SECRET_KEY=change-me-generate|WEBUI_SECRET_KEY=${webui_secret}|" "$ENV_FILE"
  sed -i "s|MCPO_API_KEY=change-me-generate|MCPO_API_KEY=${mcpo_secret}|" "$ENV_FILE"
  echo "Created $ENV_FILE from .env.example and generated local secrets."
}

ensure_env_secrets() {
  local changed=false
  if grep -qx 'WEBUI_SECRET_KEY=change-me-generate' "$ENV_FILE"; then
    sed -i "s|^WEBUI_SECRET_KEY=change-me-generate$|WEBUI_SECRET_KEY=$(new_secret)|" "$ENV_FILE"
    changed=true
  fi
  if grep -qx 'MCPO_API_KEY=change-me-generate' "$ENV_FILE"; then
    sed -i "s|^MCPO_API_KEY=change-me-generate$|MCPO_API_KEY=$(new_secret)|" "$ENV_FILE"
    changed=true
  fi
  if [[ "$changed" == true ]]; then
    echo "Replaced placeholder secrets in $ENV_FILE."
  fi
}

load_env() {
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

read_env_value() {
  local key="$1"
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key "=" {
      sub("^[[:space:]]*" key "=", "")
      print
      exit
    }
  ' "$ENV_FILE"
}

restore_raw_json_env() {
  local key="$1" raw
  raw="$(read_env_value "$key")"
  if [[ -n "$raw" ]]; then
    export "$key=$raw"
  fi
}

validate_json_env() {
  local key="$1" value
  value="${!key:-}"
  if [[ -z "$value" ]]; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    JSON_ENV_VALUE="$value" python3 - "$key" <<'PY'
import json
import os
import sys

key = sys.argv[1]
value = os.environ.get("JSON_ENV_VALUE", "")
try:
    parsed = json.loads(value)
except Exception as exc:
    print(f"[FAIL] {key} is not valid JSON: {exc}", file=sys.stderr)
    print(f"       value={value!r}", file=sys.stderr)
    sys.exit(1)
if key == "MINERU_PARAMS" and parsed:
    backend = parsed.get("backend")
    if backend != "pipeline":
        print(f"[FAIL] MINERU_PARAMS.backend must be 'pipeline' for the production-default local setup, got {backend!r}", file=sys.stderr)
        sys.exit(1)
PY
    return $?
  fi
  if command -v python >/dev/null 2>&1; then
    JSON_ENV_VALUE="$value" python - "$key" <<'PY'
import json
import os
import sys

key = sys.argv[1]
value = os.environ.get("JSON_ENV_VALUE", "")
parsed = json.loads(value)
if key == "MINERU_PARAMS" and parsed.get("backend") != "pipeline":
    raise SystemExit("MINERU_PARAMS.backend is not pipeline")
PY
    return $?
  fi
  if command -v node >/dev/null 2>&1; then
    JSON_ENV_VALUE="$value" JSON_ENV_KEY="$key" node -e '
const key = process.env.JSON_ENV_KEY;
const parsed = JSON.parse(process.env.JSON_ENV_VALUE || "");
if (key === "MINERU_PARAMS" && parsed.backend !== "pipeline") {
  console.error("[FAIL] MINERU_PARAMS.backend is not pipeline");
  process.exit(1);
}
'
    return $?
  fi
  return 0
}

verify_openwebui_mineru_params() {
  local value
  value="$(docker compose -f docker-compose.yml --env-file "$ENV_FILE" exec -T open-webui printenv MINERU_PARAMS 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    echo "  [FAIL] open-webui container has empty MINERU_PARAMS" >&2
    return 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    JSON_ENV_VALUE="$value" python3 - <<'PY'
import json
import os
import sys

value = os.environ.get("JSON_ENV_VALUE", "")
try:
    parsed = json.loads(value)
except Exception as exc:
    print(f"[FAIL] open-webui container MINERU_PARAMS is not valid JSON: {exc}", file=sys.stderr)
    print(f"       value={value!r}", file=sys.stderr)
    sys.exit(1)
backend = parsed.get("backend")
if backend != "pipeline":
    print(f"[FAIL] open-webui container MINERU_PARAMS.backend is {backend!r}, expected 'pipeline'", file=sys.stderr)
    sys.exit(1)
print("  [OK]   open-webui MINERU_PARAMS is valid JSON and uses pipeline")
PY
    return $?
  fi
  if command -v node >/dev/null 2>&1; then
    JSON_ENV_VALUE="$value" node -e '
const parsed = JSON.parse(process.env.JSON_ENV_VALUE || "");
if (parsed.backend !== "pipeline") {
  console.error(`[FAIL] open-webui container MINERU_PARAMS.backend is ${JSON.stringify(parsed.backend)}, expected "pipeline"`);
  process.exit(1);
}
console.log("  [OK]   open-webui MINERU_PARAMS is valid JSON and uses pipeline");
'
    return $?
  fi
  docker compose -f docker-compose.yml --env-file "$ENV_FILE" exec -T \
    -e JSON_ENV_VALUE="$value" open-webui python - <<'PY'
import json
import os
import sys

value = os.environ.get("JSON_ENV_VALUE", "")
try:
    parsed = json.loads(value)
except Exception as exc:
    print(f"[FAIL] open-webui container MINERU_PARAMS is not valid JSON: {exc}", file=sys.stderr)
    print(f"       value={value!r}", file=sys.stderr)
    sys.exit(1)
backend = parsed.get("backend")
if backend != "pipeline":
    print(f"[FAIL] open-webui container MINERU_PARAMS.backend is {backend!r}, expected 'pipeline'", file=sys.stderr)
    sys.exit(1)
print("  [OK]   open-webui MINERU_PARAMS is valid JSON and uses pipeline")
PY
}

wsl_windows_gateway_ip() {
  ip route | awk '/^default / { print $3; exit }'
}

http_ok() {
  local url="$1" name="$2" tries="${3:-40}"
  for ((i=0; i<tries; i++)); do
    if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
      echo "  [OK]   $name"
      return 0
    fi
    sleep 2
  done
  echo "  [DOWN] $name <- $url"
  return 1
}

json_post_ok() {
  local url="$1" body="$2" name="$3"
  if curl -fsS --max-time 25 -H 'Content-Type: application/json' -d "$body" "$url" >/dev/null; then
    echo "  [OK]   $name"
    return 0
  fi
  echo "  [WARN] $name failed"
  return 1
}

write_smoke_pdf() {
  local path="$1"
  cat > "$path" <<'PDF'
%PDF-1.4
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>
endobj
4 0 obj
<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>
endobj
5 0 obj
<< /Length 82 >>
stream
BT /F1 18 Tf 72 720 Td (Scientific assistant test PDF for MinerU pipeline.) Tj ET
endstream
endobj
xref
0 6
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000241 00000 n 
0000000311 00000 n 
trailer
<< /Size 6 /Root 1 0 R >>
startxref
442
%%EOF
PDF
}

mineru_parse_smoke_ok() {
  local url="$1" pdf="$2" out
  out="$(mktemp)"
  # Keep form fields before the file part; MinerU/FastAPI parses this path reliably.
  if curl -fsS --max-time 240 -X POST "$url/file_parse" \
    -F "backend=pipeline" \
    -F "lang_list=east_slavic" \
    -F "parse_method=auto" \
    -F "formula_enable=true" \
    -F "table_enable=true" \
    -F "return_md=true" \
    -F "files=@${pdf};type=application/pdf" \
    -o "$out"; then
    if grep -q '"status":"completed"' "$out" && grep -q '"backend":"pipeline"' "$out"; then
      rm -f "$out"
      return 0
    fi
  fi
  echo "  [WARN] MinerU smoke response:"
  head -c 1200 "$out" || true
  echo
  rm -f "$out"
  return 1
}

show_service_debug() {
  local service="$1"
  echo
  echo "--- docker compose ps $service ---"
  docker compose -f docker-compose.yml --env-file "$ENV_FILE" ps "$service" || true
  echo "--- docker compose logs --tail=120 $service ---"
  docker compose -f docker-compose.yml --env-file "$ENV_FILE" logs --tail=120 "$service" || true
  echo "--- end $service debug ---"
}

ensure_env_file
ensure_env_secrets
load_env

# Bash strips JSON quotes when sourcing .env values such as
# MINERU_PARAMS={"backend":"pipeline"}. Restore raw file values before Docker
# Compose interpolation; shell environment has precedence over --env-file.
restore_raw_json_env MINERU_PARAMS
restore_raw_json_env TOOL_SERVER_CONNECTIONS
if ! validate_json_env MINERU_PARAMS; then
  echo "Fix MINERU_PARAMS in $ENV_FILE before starting the stack." >&2
  exit 1
fi
if ! validate_json_env TOOL_SERVER_CONNECTIONS; then
  echo "Fix TOOL_SERVER_CONNECTIONS in $ENV_FILE before starting the stack." >&2
  exit 1
fi

WINDOWS_HOST_IP="${WINDOWS_HOST_IP:-}"
if [[ -z "$WINDOWS_HOST_IP" ]] && grep -qi microsoft /proc/version 2>/dev/null; then
  WINDOWS_HOST_IP="$(wsl_windows_gateway_ip || true)"
fi

# In pure WSL Docker Engine, Docker's host-gateway is the WSL Linux host, not Windows.
# Map host.docker.internal to the Windows host/gateway so containers can reach native LM Studio.
if [[ -n "$WINDOWS_HOST_IP" && "${HOST_DOCKER_INTERNAL_GATEWAY:-host-gateway}" == "host-gateway" ]]; then
  export HOST_DOCKER_INTERNAL_GATEWAY="$WINDOWS_HOST_IP"
fi

LMSTUDIO_HEALTH_URL="${LMSTUDIO_HEALTH_URL:-}"
if [[ -z "$LMSTUDIO_HEALTH_URL" || "$LMSTUDIO_HEALTH_URL" == "http://127.0.0.1:1234/v1/models" ]]; then
  if [[ -n "$WINDOWS_HOST_IP" ]]; then
    LMSTUDIO_HEALTH_URL="http://${WINDOWS_HOST_IP}:1234/v1/models"
  else
    LMSTUDIO_HEALTH_URL="http://127.0.0.1:1234/v1/models"
  fi
fi
export LMSTUDIO_HEALTH_URL

WEBUI_PORT="${WEBUI_PORT:-3000}"
INFINITY_PORT="${INFINITY_PORT:-7997}"
MCPO_PORT="${MCPO_PORT:-8001}"
MINERU_PORT="${MINERU_PORT:-8000}"
OPENWEBUI_HEALTH_TRIES="${OPENWEBUI_HEALTH_TRIES:-60}"
INFINITY_HEALTH_TRIES="${INFINITY_HEALTH_TRIES:-180}"
MCPO_HEALTH_TRIES="${MCPO_HEALTH_TRIES:-60}"
MINERU_HEALTH_TRIES="${MINERU_HEALTH_TRIES:-60}"
INFINITY_EMBED_MODEL="${INFINITY_EMBED_MODEL:-BAAI/bge-m3}"
INFINITY_RERANK_MODEL="${INFINITY_RERANK_MODEL:-BAAI/bge-reranker-v2-m3}"
DOCKER_GPU_SMOKE_TEST="${DOCKER_GPU_SMOKE_TEST:-true}"
FUNCTIONAL_SMOKE_TEST="${FUNCTIONAL_SMOKE_TEST:-true}"

cat <<EOF
Preflight
  Mode: Linux/WSL Docker Engine path
  Windows host IP: ${WINDOWS_HOST_IP:-not-detected}
  HOST_DOCKER_INTERNAL_GATEWAY: ${HOST_DOCKER_INTERNAL_GATEWAY:-host-gateway}
  LM Studio health URL: $LMSTUDIO_HEALTH_URL
EOF

command -v docker >/dev/null 2>&1 || { echo "docker command not found" >&2; exit 1; }

if grep -qi microsoft /proc/version 2>/dev/null; then
  current_engine="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)"
  if printf '%s' "$current_engine" | grep -qi 'Docker Desktop'; then
    if [[ -S /var/run/docker.sock ]]; then
      export DOCKER_HOST=unix:///var/run/docker.sock
    fi
  fi
fi

docker compose version
docker info >/dev/null
echo "  [OK]   Docker daemon is reachable"
docker info --format '  Engine: {{.OperatingSystem}} / {{.OSType}} / {{.KernelVersion}}'
engine_after="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)"
if printf '%s' "$engine_after" | grep -qi 'Docker Desktop'; then
  echo "  [FAIL] Docker Desktop backend detected. Server-like mode requires native Docker Engine inside WSL." >&2
  echo "         Run ./setup_all.sh and choose NVIDIA/native Docker setup, or export DOCKER_HOST=unix:///var/run/docker.sock after starting native Docker." >&2
  exit 1
fi

if [[ "$SKIP_GPU_TEST" != true && "$DOCKER_GPU_SMOKE_TEST" != false ]]; then
  echo "  Docker GPU smoke test (may pull CUDA image on first run)..."
  docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
  echo "  [OK]   Docker can see NVIDIA GPU(s)"
else
  echo "  [SKIP] Docker GPU smoke test"
fi

echo
echo "LM Studio check"
lm_ok=false
if http_ok "$LMSTUDIO_HEALTH_URL" "LM Studio models endpoint" 5; then
  lm_ok=true
  models_json="$(curl -fsS --max-time 5 "$LMSTUDIO_HEALTH_URL" || true)"
  model_for_chat="$(printf '%s' "$models_json" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  if [[ -n "$model_for_chat" ]]; then
    echo "  First loaded model: $model_for_chat"
  fi
else
  model_for_chat=""
  echo "  [HINT] LM Studio is not reachable from WSL at $LMSTUDIO_HEALTH_URL."
  echo "         In LM Studio Server Settings enable access from the local network / bind to 0.0.0.0,"
  echo "         then make sure Windows Firewall allows port 1234 from WSL."
fi

echo
echo "Starting Docker stack"
compose_args=(compose -f docker-compose.yml --env-file "$ENV_FILE" up -d)
if [[ "$NO_BUILD" != true ]]; then
  compose_args+=(--build)
fi
docker "${compose_args[@]}"

if ! verify_openwebui_mineru_params; then
  echo "Recreating open-webui with the corrected MINERU_PARAMS from $ENV_FILE..."
  docker compose -f docker-compose.yml --env-file "$ENV_FILE" up -d --force-recreate --no-deps open-webui
  verify_openwebui_mineru_params
fi

echo
echo "Health check"
owui=false; inf=false; mcp=false; min=false
http_ok "http://127.0.0.1:${WEBUI_PORT}" "Open WebUI (:${WEBUI_PORT})" "$OPENWEBUI_HEALTH_TRIES" && owui=true || true
http_ok "http://127.0.0.1:${INFINITY_PORT}/health" "Infinity (:${INFINITY_PORT})" "$INFINITY_HEALTH_TRIES" && inf=true || true
http_ok "http://127.0.0.1:${MCPO_PORT}/docs" "mcpo/MCP (:${MCPO_PORT})" "$MCPO_HEALTH_TRIES" && mcp=true || true
http_ok "http://127.0.0.1:${MINERU_PORT}/docs" "MinerU (:${MINERU_PORT})" "$MINERU_HEALTH_TRIES" && min=true || true

if [[ "$inf" != true ]]; then show_service_debug infinity; fi
if [[ "$owui" != true ]]; then show_service_debug open-webui; fi
if [[ "$mcp" != true ]]; then show_service_debug mcpo; fi
if [[ "$min" != true ]]; then show_service_debug mineru; fi

if [[ "$SKIP_FUNCTIONAL" != true && "$FUNCTIONAL_SMOKE_TEST" != false ]]; then
  echo
  echo "Functional smoke checks"
  if [[ -n "${model_for_chat:-}" ]]; then
    chat_url="${LMSTUDIO_HEALTH_URL%/models}/chat/completions"
    json_post_ok "$chat_url" "{\"model\":\"$model_for_chat\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK only.\"}],\"max_tokens\":8,\"temperature\":0}" "LM Studio chat completion" || true
  else
    echo "  [SKIP] LM Studio chat completion: no model id available"
  fi
  json_post_ok "http://127.0.0.1:${INFINITY_PORT}/embeddings" "{\"model\":\"$INFINITY_EMBED_MODEL\",\"input\":[\"test\"]}" "Infinity embeddings" || true
  json_post_ok "http://127.0.0.1:${INFINITY_PORT}/rerank" "{\"model\":\"$INFINITY_RERANK_MODEL\",\"query\":\"scientific writing\",\"documents\":[\"Scientific writing requires citations.\",\"Bananas are yellow.\"]}" "Infinity rerank" || true
  smoke_pdf="$(mktemp --suffix=.pdf)"
  if write_smoke_pdf "$smoke_pdf" && mineru_parse_smoke_ok "http://127.0.0.1:${MINERU_PORT}" "$smoke_pdf"; then
    echo "  [OK]   MinerU pipeline PDF parse"
  else
    echo "  [WARN] MinerU pipeline PDF parse failed"
  fi
  rm -f "$smoke_pdf"
fi

echo
if [[ "$lm_ok" == true && "$owui" == true && "$inf" == true && "$mcp" == true && "$min" == true ]]; then
  echo "ALL CORE SERVICES UP. Open WebUI: http://localhost:${WEBUI_PORT}"
  echo "Inside Open WebUI use: Infinity http://infinity:7997, MinerU http://mineru:8000, mcpo http://mcpo:8001"
else
  echo "SOME SERVICES DOWN. Useful commands:"
  echo "  docker compose --env-file $ENV_FILE ps"
  echo "  docker compose --env-file $ENV_FILE logs open-webui infinity mcpo mineru"
fi
