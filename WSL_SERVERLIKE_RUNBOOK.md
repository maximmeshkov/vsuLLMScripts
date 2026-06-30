# WSL server-like local test

This path mirrors the intended Windows Server layout more closely than Docker Desktop:

```text
Windows
├─ LM Studio native Windows, :1234
└─ WSL2 Debian/Ubuntu
   └─ Docker Engine inside Debian/Ubuntu
      ├─ Open WebUI
      ├─ Infinity
      ├─ mcpo
      └─ MinerU
```

## 1. Install WSL Debian/Ubuntu

In Windows PowerShell:

```powershell
wsl --install -d Debian
wsl --update
wsl -l -v
```

Reboot if Windows asks.

## 2. Install Docker Engine inside Debian/Ubuntu

Inside Debian:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
docker run --rm hello-world
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

If the GPU command fails, install/configure NVIDIA Container Toolkit in the Debian distro.

## 3. Put the project inside Linux filesystem

Do not run the server-like test from `/mnt/c/...` if you can avoid it. Copy it to Linux home:

```bash
mkdir -p ~/sci-assistant
cp -a /mnt/c/Users/maxim/sci-assistant/. ~/sci-assistant/
cd ~/sci-assistant
chmod +x start-all.sh
```

Stop the Docker Desktop copy first if it is using the same ports:

```powershell
cd C:\Users\maxim\sci-assistant
docker compose --env-file .env down
```

## 4. LM Studio networking

LM Studio stays native on Windows. Start the server on port 1234 and make sure Windows Firewall allows WSL to reach it.

The Linux script auto-detects the Windows gateway IP and maps `host.docker.internal` to it for containers by exporting `HOST_DOCKER_INTERNAL_GATEWAY`.

If auto-detection fails, set these in `.env` inside `~/sci-assistant`:

```env
WINDOWS_HOST_IP=<windows-host-ip-visible-from-wsl>
HOST_DOCKER_INTERNAL_GATEWAY=<same-ip>
LMSTUDIO_BASE_URL=http://host.docker.internal:1234/v1
LMSTUDIO_HEALTH_URL=http://<same-ip>:1234/v1/models
```

## 5. Start exactly like the server path

Inside Debian:

```bash
cd ~/sci-assistant
./start-all.sh
```

Optional fast start without rebuilding:

```bash
./start-all.sh --no-build
```

Optional skip GPU smoke test:

```bash
./start-all.sh --skip-gpu-test
```

## 6. Server heavy model later

Use the same scripts. Only change the model loaded in LM Studio and optionally set:

```env
EXPECTED_LMSTUDIO_MODEL=part-of-heavy-model-id
```

The Docker services do not know which chat model you loaded; they only talk to LM Studio's OpenAI-compatible API.

