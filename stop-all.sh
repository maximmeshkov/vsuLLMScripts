#!/usr/bin/env bash
set -euo pipefail

# stop-all.sh - stop the server-like Linux/WSL Docker stack.
# Default is non-destructive: stop containers but keep containers, networks, data, and volumes.

ENV_FILE=".env"
ACTION="stop"
STOP_DOCKER=false

usage() {
  cat <<USAGE
Usage: ./stop-all.sh [--stop|--down|--volumes|--status] [--stop-docker] [--env-file FILE]

Actions:
  --stop       Stop compose containers only (default, non-destructive).
  --down       Remove compose containers and network, keep volumes/data.
  --volumes    Remove compose containers, network, and compose volumes. Destructive for Infinity cache.
  --status     Show compose status only.

Extra:
  --stop-docker  Stop the native Docker daemon after the compose action.
  --env-file F   Use a different env file.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop) ACTION="stop" ;;
    --down) ACTION="down" ;;
    --volumes) ACTION="volumes" ;;
    --status) ACTION="status" ;;
    --stop-docker) STOP_DOCKER=true ;;
    --env-file) ENV_FILE="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

cd "$(dirname "${BASH_SOURCE[0]}")"

command -v docker >/dev/null 2>&1 || { echo "docker command not found" >&2; exit 1; }

if grep -qi microsoft /proc/version 2>/dev/null; then
  current_engine="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)"
  if printf '%s' "$current_engine" | grep -qi 'Docker Desktop'; then
    if [[ -S /var/run/docker.sock ]]; then
      export DOCKER_HOST=unix:///var/run/docker.sock
    fi
  fi
fi

docker info >/dev/null
engine_after="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)"
if printf '%s' "$engine_after" | grep -qi 'Docker Desktop'; then
  echo "[FAIL] Docker Desktop backend detected. This script targets native Docker Engine inside WSL/server." >&2
  exit 1
fi

echo "Docker engine: $(docker info --format '{{.OperatingSystem}} / {{.OSType}} / {{.KernelVersion}}')"

case "$ACTION" in
  status)
    docker compose -f docker-compose.yml --env-file "$ENV_FILE" ps
    ;;
  stop)
    docker compose -f docker-compose.yml --env-file "$ENV_FILE" stop
    ;;
  down)
    docker compose -f docker-compose.yml --env-file "$ENV_FILE" down
    ;;
  volumes)
    echo "Removing compose containers, network, and volumes for this project. Bind-mounted ./data, ./papers, ./mcp-data stay on disk."
    docker compose -f docker-compose.yml --env-file "$ENV_FILE" down -v
    ;;
esac

if [[ "$STOP_DOCKER" == true ]]; then
  echo "Stopping native Docker daemon..."
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files docker.service >/dev/null 2>&1; then
    sudo systemctl stop docker
  else
    sudo service docker stop
  fi
fi

echo "stop-all.sh finished."