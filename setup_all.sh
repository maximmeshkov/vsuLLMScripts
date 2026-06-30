#!/usr/bin/env bash
set -euo pipefail

# setup_all.sh - interactive setup inside Debian/WSL or Linux server.
# It asks before installing Docker, starting services, running GPU tests, or starting the stack.

cd "$(dirname "${BASH_SOURCE[0]}")"

ask_yes_no() {
  local question="$1" default="${2:-n}" suffix answer
  if [[ "$default" == "y" ]]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
  while true; do
    read -r -p "$question $suffix " answer || true
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Please answer y/n." ;;
    esac
  done
}

start_docker_daemon() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    if command -v service >/dev/null 2>&1; then
      sudo service docker start || true
    fi
    if command -v systemctl >/dev/null 2>&1; then
      sudo systemctl start docker || true
    fi
  fi
}

try_use_native_docker_socket() {
  if [[ -S /var/run/docker.sock ]]; then
    export DOCKER_HOST=unix:///var/run/docker.sock
    if docker info >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo docker "$@"
  else
    docker "$@"
  fi
}

install_docker_engine() {
  curl -fsSL https://get.docker.com | sh
  if command -v sudo >/dev/null 2>&1; then
    sudo usermod -aG docker "$USER" || true
    echo "Added $USER to docker group if possible. You may need to reopen the WSL shell later."
  fi
}
install_nvidia_container_toolkit() {
  if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo is required to install/configure NVIDIA Container Toolkit."
    return 1
  fi

  sudo apt-get update
  sudo apt-get install -y --no-install-recommends ca-certificates curl gnupg2

  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

  sudo apt-get update
  sudo apt-get install -y nvidia-container-toolkit

  sudo nvidia-ctk runtime configure --runtime=docker

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl restart docker || true
  fi
  if command -v service >/dev/null 2>&1; then
    sudo service docker restart || true
  fi

  if command -v nvidia-ctk >/dev/null 2>&1; then
    sudo mkdir -p /var/run/cdi
    sudo nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml || true
    nvidia-ctk cdi list || true
  fi
}

run_gpu_smoke_test() {
  docker_cmd run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
}

engine_summary() {
  docker info --format '{{.OperatingSystem}} / {{.OSType}} / {{.KernelVersion}}' 2>/dev/null || true
}

echo "Scientific assistant Linux/WSL interactive setup"
echo "Project: $(pwd)"
echo "Kernel: $(uname -a)"
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  echo "Distro: ${PRETTY_NAME:-unknown}"
fi
if grep -qi microsoft /proc/version 2>/dev/null; then
  echo "Mode: WSL detected"
else
  echo "Mode: non-WSL Linux detected"
fi

echo
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker command not found."
  if ask_yes_no "Install native Docker Engine using get.docker.com? This needs network and sudo." n; then
    install_docker_engine
  else
    echo "Skipping Docker install. start-all.sh cannot run until Docker Engine is available."
  fi
else
  echo "Docker command found: $(command -v docker)"
fi

if command -v docker >/dev/null 2>&1; then
  if ! docker info >/dev/null 2>&1; then
    if ask_yes_no "Docker daemon is not reachable. Try to start native Docker daemon now?" y; then
      start_docker_daemon
    fi
  fi

  if docker info >/dev/null 2>&1; then
    summary="$(engine_summary)"
    docker compose version || true
    echo "Engine=$summary"

    if printf '%s' "$summary" | grep -qi 'Docker Desktop'; then
      echo
      echo "WARNING: Docker currently points to Docker Desktop backend."
      echo "Server-like mode requires native Docker Engine inside this WSL distro."
      if ask_yes_no "Install/start native Docker Engine inside this WSL distro and use /var/run/docker.sock?" y; then
        install_docker_engine
        start_docker_daemon
        if try_use_native_docker_socket; then
          echo "Using native Docker Engine: $(engine_summary)"
        else
          echo "Native Docker Engine is not reachable via /var/run/docker.sock. Stop here and fix Docker Engine setup."
          exit 1
        fi
      else
        echo "Stopping before stack start because Docker Desktop backend is not server-like."
        exit 0
      fi
    fi
  else
    echo "Docker daemon is still not reachable."
  fi
fi

echo
if command -v docker >/dev/null 2>&1 && docker_cmd info >/dev/null 2>&1; then
  if ask_yes_no "Run Docker GPU smoke test with nvidia/cuda image?" y; then
    if run_gpu_smoke_test; then
      echo "Docker GPU smoke test passed."
    else
      echo
      echo "Docker GPU smoke test failed. Native Docker Engine likely needs NVIDIA Container Toolkit/CDI configuration."
      if ask_yes_no "Install/configure NVIDIA Container Toolkit and retry GPU smoke test?" y; then
        install_nvidia_container_toolkit
        if run_gpu_smoke_test; then
          echo "Docker GPU smoke test passed after NVIDIA Container Toolkit setup."
        else
          echo "Docker GPU smoke test still failed. Stop here and inspect Docker/NVIDIA setup."
          exit 1
        fi
      else
        echo "Stopping before stack start because GPU access is not verified."
        exit 1
      fi
    fi
  fi
fi

echo
if [[ -f .env ]]; then
  echo ".env exists."
else
  echo ".env does not exist; start-all.sh will create it from .env.example and generate secrets."
fi

if ask_yes_no "Start the full assistant stack now with ./start-all.sh?" y; then
  ./start-all.sh
else
  echo "Later, start with: ./start-all.sh"
fi

echo
echo "After startup, run diagnostics with:"
echo "  ./doctor.sh"
echo "  ./doctor.sh --deep"

echo "setup_all.sh finished."
