#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ENV_FILE="${ENV_FILE:-.env}"
if [[ $# -gt 0 ]]; then
  SERVICES="$*"
else
  SERVICES="${SERVICES:-open-webui mineru infinity mcpo}"
fi

echo "Watching sci-assistant logs. Press Ctrl+C to stop this window."
echo "Project: $(pwd)"
echo "Services: $SERVICES"
echo

# shellcheck disable=SC2086
exec docker compose --env-file "$ENV_FILE" logs -f --tail=120 $SERVICES
