#!/usr/bin/env bash
set -u

# doctor.sh - read-only diagnostics for the sci-assistant stack.
# It prints PASS/FAIL without dumping API keys or secrets.

cd "$(dirname "${BASH_SOURCE[0]}")"

ENV_FILE=".env"
DEEP=false
GPU_SMOKE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift ;;
    --deep) DEEP=true ;;
    --gpu-smoke) GPU_SMOKE=true ;;
    -h|--help)
      cat <<'USAGE'
Usage: ./doctor.sh [--deep] [--gpu-smoke] [--env-file FILE]

Default checks are read-only and quick:
  Docker/native engine, compose config, service status, HTTP health,
  Open WebUI wiring, LM Studio reachability, and recent error hints.

Options:
  --deep       Run functional checks: LM Studio chat, Infinity embeddings/rerank/CLIP, image-RAG, MinerU PDF parse.
  --gpu-smoke  Run Docker CUDA nvidia-smi smoke test. This may pull an image.
USAGE
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

fails=0
warns=0

pass() { printf '[PASS] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; warns=$((warns + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; fails=$((fails + 1)); }
info() { printf '[INFO] %s\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    fail "Missing $ENV_FILE. Run ./start-all.sh once or copy .env.example to .env."
    return 1
  fi
  sed -i 's/\r$//' "$ENV_FILE"
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

json_env_valid() {
  local key="$1" value
  value="${!key:-}"
  [[ -z "$value" ]] && return 0
  if command -v python3 >/dev/null 2>&1; then
    JSON_ENV_VALUE="$value" python3 - "$key" <<'PY'
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
  process.exit(1);
}
'
    return $?
  fi
  return 0
}

container_mineru_params_valid() {
  local value
  value="$(docker compose --env-file "$ENV_FILE" exec -T open-webui printenv MINERU_PARAMS 2>/dev/null || true)"
  [[ -n "$value" ]] || return 1
  if command -v python3 >/dev/null 2>&1; then
    JSON_ENV_VALUE="$value" python3 - <<'PY'
import json
import os

value = os.environ.get("JSON_ENV_VALUE", "")
parsed = json.loads(value)
if parsed.get("backend") != "pipeline":
    raise SystemExit("backend is not pipeline")
PY
    return $?
  fi
  if command -v node >/dev/null 2>&1; then
    JSON_ENV_VALUE="$value" node -e '
const parsed = JSON.parse(process.env.JSON_ENV_VALUE || "");
if (parsed.backend !== "pipeline") process.exit(1);
'
    return $?
  fi
  docker compose --env-file "$ENV_FILE" exec -T \
    -e JSON_ENV_VALUE="$value" open-webui python - <<'PY'
import json
import os

value = os.environ.get("JSON_ENV_VALUE", "")
parsed = json.loads(value)
if parsed.get("backend") != "pipeline":
    raise SystemExit("backend is not pipeline")
PY
}

container_embedding_limits_valid() {
  local batch concurrent
  batch="$(docker compose --env-file "$ENV_FILE" exec -T open-webui printenv RAG_EMBEDDING_BATCH_SIZE 2>/dev/null || true)"
  concurrent="$(docker compose --env-file "$ENV_FILE" exec -T open-webui printenv RAG_EMBEDDING_CONCURRENT_REQUESTS 2>/dev/null || true)"
  [[ "${batch:-}" == "1" ]] || return 1
  [[ "${concurrent:-}" == "1" ]] || return 1
}

wsl_windows_gateway_ip() {
  ip route | awk '/^default / { print $3; exit }'
}

http_ok() {
  local url="$1"
  curl -fsS --max-time 5 "$url" >/dev/null 2>&1
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

json_post_ok() {
  local url="$1" body="$2"
  curl -fsS --max-time 30 -H 'Content-Type: application/json' -d "$body" "$url" >/dev/null 2>&1
}

mineru_pipeline_smoke_ok() {
  local pdf out status
  pdf="$(mktemp --suffix=.pdf)"
  out="$(mktemp)"
  write_smoke_pdf "$pdf"
  if curl -fsS --max-time 240 -X POST "http://127.0.0.1:${MINERU_PORT:-8000}/file_parse" \
    -F "backend=pipeline" \
    -F "lang_list=east_slavic" \
    -F "parse_method=auto" \
    -F "formula_enable=true" \
    -F "table_enable=true" \
    -F "return_md=true" \
    -F "files=@${pdf};type=application/pdf" \
    -o "$out"; then
    if grep -q '"status":"completed"' "$out" && grep -q '"backend":"pipeline"' "$out"; then
      rm -f "$pdf" "$out"
      return 0
    fi
  fi
  status="$(head -c 500 "$out" 2>/dev/null || true)"
  rm -f "$pdf" "$out"
  info "MinerU smoke response: $status"
  return 1
}

echo "sci-assistant doctor"
echo "Project: $(pwd)"
echo

load_env || true
restore_raw_json_env MINERU_PARAMS
restore_raw_json_env TOOL_SERVER_CONNECTIONS

if json_env_valid MINERU_PARAMS; then
  pass "MINERU_PARAMS is valid JSON and requests pipeline"
else
  fail "MINERU_PARAMS in $ENV_FILE is invalid JSON or not pipeline"
fi

if json_env_valid TOOL_SERVER_CONNECTIONS; then
  pass "TOOL_SERVER_CONNECTIONS is valid JSON"
else
  fail "TOOL_SERVER_CONNECTIONS in $ENV_FILE is invalid JSON"
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  info "Linux distro: ${PRETTY_NAME:-unknown}"
fi
if grep -qi microsoft /proc/version 2>/dev/null; then
  info "WSL detected"
else
  info "Non-WSL Linux detected"
fi

if have docker; then
  pass "docker command exists: $(command -v docker)"
else
  fail "docker command missing. In WSL run: curl -fsSL https://get.docker.com | sh"
fi

if docker info >/dev/null 2>&1; then
  engine="$(docker info --format '{{.OperatingSystem}} / {{.OSType}} / {{.KernelVersion}}' 2>/dev/null || true)"
  if printf '%s' "$engine" | grep -qi 'Docker Desktop'; then
    fail "Docker points to Docker Desktop backend. Server target must use native Docker Engine inside WSL."
  else
    pass "Docker daemon reachable: $engine"
  fi
else
  fail "Docker daemon is not reachable. Try: sudo service docker start"
fi

if docker compose version >/dev/null 2>&1; then
  pass "$(docker compose version)"
else
  fail "docker compose v2 missing"
fi

if [[ -f docker-compose.yml ]]; then
  if docker compose --env-file "$ENV_FILE" config >/tmp/sci-assistant-doctor-compose.yml 2>/tmp/sci-assistant-doctor-compose.err; then
    pass "docker compose config is valid"
    for needle in \
      'CONTENT_EXTRACTION_ENGINE: mineru' \
      'MINERU_API_URL: http://mineru:8000' \
      'ENABLE_RAG_HYBRID_SEARCH: "true"' \
      'RAG_RERANKING_ENGINE: external' \
      'RAG_EXTERNAL_RERANKER_URL: http://infinity:7997/rerank' \
      'http://image-rag:8010' \
      'TOOL_SERVER_CONNECTIONS:'; do
      if grep -Fq "$needle" /tmp/sci-assistant-doctor-compose.yml; then
        pass "compose contains $needle"
      else
        fail "compose missing $needle"
      fi
    done
  else
    fail "docker compose config failed:"
    sed -n '1,80p' /tmp/sci-assistant-doctor-compose.err
  fi
else
  fail "docker-compose.yml missing"
fi

if have nvidia-smi; then
  pass "nvidia-smi exists"
  nvidia-smi --query-gpu=index,name,memory.total,memory.used --format=csv,noheader,nounits 2>/dev/null | sed 's/^/[INFO] GPU /' || true
else
  warn "nvidia-smi missing in WSL. GPU containers may still work only if WSL/NVIDIA is configured correctly."
fi

if [[ "$GPU_SMOKE" == true ]]; then
  if docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/tmp/sci-assistant-doctor-gpu.txt 2>&1; then
    pass "Docker GPU smoke test passed"
  else
    fail "Docker GPU smoke test failed. Inspect /tmp/sci-assistant-doctor-gpu.txt"
  fi
fi

WINDOWS_HOST_IP="${WINDOWS_HOST_IP:-}"
if [[ -z "$WINDOWS_HOST_IP" ]] && grep -qi microsoft /proc/version 2>/dev/null; then
  WINDOWS_HOST_IP="$(wsl_windows_gateway_ip || true)"
fi
LMSTUDIO_HEALTH_URL="${LMSTUDIO_HEALTH_URL:-}"
if [[ -z "$LMSTUDIO_HEALTH_URL" || "$LMSTUDIO_HEALTH_URL" == "http://127.0.0.1:1234/v1/models" ]]; then
  if [[ -n "$WINDOWS_HOST_IP" ]]; then
    LMSTUDIO_HEALTH_URL="http://${WINDOWS_HOST_IP}:1234/v1/models"
  else
    LMSTUDIO_HEALTH_URL="http://127.0.0.1:1234/v1/models"
  fi
fi
info "LM Studio health URL: $LMSTUDIO_HEALTH_URL"
if http_ok "$LMSTUDIO_HEALTH_URL"; then
  pass "LM Studio /v1/models reachable"
else
  fail "LM Studio not reachable. In LM Studio enable Serve on Local Network and allow Windows Firewall port 1234."
fi

if docker compose --env-file "$ENV_FILE" ps >/tmp/sci-assistant-doctor-ps.txt 2>/dev/null; then
  info "compose ps:"
  sed 's/^/[INFO] /' /tmp/sci-assistant-doctor-ps.txt
else
  warn "docker compose ps failed"
fi

if container_mineru_params_valid; then
  pass "open-webui container MINERU_PARAMS is valid JSON and uses pipeline"
else
  fail "open-webui container MINERU_PARAMS is missing, invalid JSON, or not pipeline; recreate open-webui with ./start-all.sh --no-build"
fi

if container_embedding_limits_valid; then
  pass "open-webui embedding batch/concurrency limits are conservative"
else
  fail "open-webui embedding limits are not RAG_EMBEDDING_BATCH_SIZE=1 and RAG_EMBEDDING_CONCURRENT_REQUESTS=1"
fi

WEBUI_PORT="${WEBUI_PORT:-3000}"
INFINITY_PORT="${INFINITY_PORT:-7997}"
MCPO_PORT="${MCPO_PORT:-8001}"
MINERU_PORT="${MINERU_PORT:-8000}"
IMAGE_RAG_PORT="${IMAGE_RAG_PORT:-8010}"
http_ok "http://127.0.0.1:${WEBUI_PORT}" && pass "Open WebUI HTTP reachable" || fail "Open WebUI HTTP down"
http_ok "http://127.0.0.1:${INFINITY_PORT}/health" && pass "Infinity health reachable" || fail "Infinity health down"
http_ok "http://127.0.0.1:${MCPO_PORT}/docs" && pass "mcpo docs reachable" || fail "mcpo docs down"
http_ok "http://127.0.0.1:${MINERU_PORT}/docs" && pass "MinerU docs reachable" || fail "MinerU docs down"
http_ok "http://127.0.0.1:${IMAGE_RAG_PORT}/health" && pass "image-rag health reachable" || fail "image-rag health down"

if [[ "$DEEP" == true ]]; then
  echo
  echo "Deep functional checks"
  models_json="$(curl -fsS --max-time 5 "$LMSTUDIO_HEALTH_URL" 2>/dev/null || true)"
  model_for_chat="$(printf '%s' "$models_json" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  if [[ -n "$model_for_chat" ]]; then
    chat_url="${LMSTUDIO_HEALTH_URL%/models}/chat/completions"
    if json_post_ok "$chat_url" "{\"model\":\"$model_for_chat\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK only.\"}],\"max_tokens\":8,\"temperature\":0}"; then
      pass "LM Studio chat completion"
    else
      fail "LM Studio chat completion failed"
    fi
  else
    warn "No LM Studio model id found, skipping chat completion"
  fi
  if json_post_ok "http://127.0.0.1:${INFINITY_PORT}/embeddings" "{\"model\":\"${INFINITY_EMBED_MODEL:-BAAI/bge-m3}\",\"input\":[\"test\"]}"; then
    pass "Infinity embeddings"
  else
    fail "Infinity embeddings failed"
  fi
  if json_post_ok "http://127.0.0.1:${INFINITY_PORT}/rerank" "{\"model\":\"${INFINITY_RERANK_MODEL:-BAAI/bge-reranker-v2-m3}\",\"query\":\"scientific writing\",\"documents\":[\"Scientific writing requires citations.\",\"Bananas are yellow.\"]}"; then
    pass "Infinity rerank"
  else
    fail "Infinity rerank failed"
  fi
  if json_post_ok "http://127.0.0.1:${INFINITY_PORT}/embeddings" "{\"model\":\"${INFINITY_IMAGE_EMBED_MODEL:-jinaai/jina-clip-v1}\",\"input\":[\"scientific plot with labeled axes\"]}"; then
    pass "Infinity CLIP text-side embeddings"
  else
    fail "Infinity CLIP text-side embeddings failed"
  fi
  image_key="${IMAGE_RAG_API_KEY:-}"
  if [[ -n "$image_key" && "$image_key" != "change-me-generate" ]]; then
    if curl -fsS --max-time 10 -H "Authorization: Bearer $image_key" -H "Content-Type: application/json" \
        -d '{"query":"scientific plot with labeled axes","limit":1}' \
        "http://127.0.0.1:${IMAGE_RAG_PORT}/search" >/tmp/sci-assistant-image-rag-search.json 2>/dev/null; then
      pass "image-rag visual search API"
    else
      fail "image-rag visual search API failed"
    fi
  else
    warn "IMAGE_RAG_API_KEY missing, skipping image-rag search API"
  fi
  if mineru_pipeline_smoke_ok; then
    pass "MinerU pipeline PDF parse"
  else
    fail "MinerU pipeline PDF parse failed"
  fi
fi

echo
if [[ "$fails" -eq 0 ]]; then
  pass "doctor finished: $warns warning(s), 0 failure(s)"
  exit 0
fi

fail "doctor finished: $fails failure(s), $warns warning(s)"
echo
echo "Useful next commands:"
echo "  docker compose --env-file $ENV_FILE ps"
echo "  docker compose --env-file $ENV_FILE logs --tail=200 open-webui infinity mcpo mineru image-rag"
echo "  ./start-all.sh --no-build"
exit 1
