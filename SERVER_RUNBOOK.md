# Server runbook: Windows Server + WSL2 Docker + native LM Studio

Target architecture:

```text
Windows Server
  LM Studio native Windows, 2xH100, OpenAI-compatible API on :1234
WSL2 Debian/Ubuntu or another Linux Docker host
  Open WebUI (:3000 published)
  Infinity embeddings/rerank (:7997 localhost)
  mcpo MCP tools (:8001 localhost)
  MinerU PDF parser (:8000 localhost)
```

For the shortest no-Codex launch path, use `SERVER_LAUNCH_CHECKLIST.md`.

## Why WSL2 Docker Engine, not Docker Desktop

Docker on Windows Server is real, but there are different products:

- Windows Server containers run with Windows container runtimes.
- This project uses Linux images, so it needs a Linux Docker engine.
- Docker Desktop is not the clean server target; use Docker Engine inside WSL2 Ubuntu or a Linux VM.

## First server checks

In Windows PowerShell:

```powershell
wsl --install -d Debian
wsl --update
```

In Ubuntu/WSL:

```bash
nvidia-smi
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
docker run --rm hello-world
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

The last command must show both H100 GPUs before relying on GPU-backed Infinity/MinerU.

## LM Studio networking

LM Studio runs natively on Windows. Containers run in Linux. If `host.docker.internal` works from containers, keep:

```env
LMSTUDIO_BASE_URL=http://host.docker.internal:1234/v1
```

If it does not work, set the Windows host IP visible from WSL:

```env
LMSTUDIO_BASE_URL=http://<windows-host-ip>:1234/v1
```

LM Studio must listen on an address reachable from WSL/containers, not only a loopback address hidden from them. Add a Windows Firewall allow rule for port 1234 if needed.

## Light local test

1. Load a small/light chat model in LM Studio.
2. Start the LM Studio server on port 1234.
3. Optionally set in `.env`:

```env
EXPECTED_LMSTUDIO_MODEL=part-of-light-model-id
```

4. Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\start-all.ps1
```

Use `-GpuTest` when you want the Docker CUDA smoke test as part of startup:

```powershell
powershell -ExecutionPolicy Bypass -File .\start-all.ps1 -GpuTest
```

## Server/heavy model

Use the same scripts. Change only LM Studio model and, if needed, `.env`:

```env
EXPECTED_LMSTUDIO_MODEL=part-of-heavy-model-id
LMSTUDIO_BASE_URL=http://<windows-host-ip-or-host.docker.internal>:1234/v1
```

For 3-7 users, prefer one strong main model in LM Studio plus dedicated RAG models in Infinity. Do not bake the chat model into docker-compose; LM Studio is the model switch.

## Open WebUI one-time settings

Detailed UI paths and exact container-vs-browser URLs are in `OPENWEBUI_SETUP.md`.

Critical values:

- LM Studio from Open WebUI: `http://host.docker.internal:1234/v1`
- Embeddings from Open WebUI: `http://infinity:7997`, model `BAAI/bge-m3`
- Rerank from Open WebUI: `Hybrid Search` enabled plus external reranker `http://infinity:7997/rerank`, model `BAAI/bge-reranker-v2-m3`
- MinerU from Open WebUI: `CONTENT_EXTRACTION_ENGINE=mineru`, local API `http://mineru:8000`, endpoint `/file_parse`, params `backend=pipeline`, `lang_list=[east_slavic]` for RU+EN local testing
- mcpo from Open WebUI: auto-wired as OpenAPI tool servers via `TOOL_SERVER_CONNECTIONS`; specs are under `http://mcpo:8001/<name>/openapi.json`

Important: Infinity exposing `/rerank` is not enough. Open WebUI must have `ENABLE_RAG_HYBRID_SEARCH=true`, `RAG_RERANKING_ENGINE=external`, and `RAG_EXTERNAL_RERANKER_URL=http://infinity:7997/rerank`, or the UI must be set to the same values.

## Stopping

From Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\stop_all.ps1
```

The wrapper asks which WSL distro and which action:

- `stop`: stop containers only, non-destructive.
- `down`: remove compose containers and network, keep data and volumes.
- `down -v`: remove compose containers, network, and compose volumes. This is intentionally guarded.
- `status`: show container status.
- stop native Docker daemon.
- `wsl --shutdown`: stop all WSL distros.

From inside WSL/Linux:

```bash
cd ~/sci-assistant
./stop-all.sh --stop      # normal non-destructive stop
./stop-all.sh --down      # remove containers/network, keep data/volumes
./stop-all.sh --volumes   # destructive for compose volumes/cache
./stop-all.sh --status
```

LM Studio is a native Windows app, so stop its local server in LM Studio separately.

## Backups

Back up these paths:

```text
./data                 Open WebUI accounts, chats, knowledge DB, uploaded files
./mcp-data/memory.jsonl MCP memory
./papers               optional local article corpus
docker volume infinity-cache
```

