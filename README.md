# VSU LLM Scripts

Server-like Windows + WSL deployment for a small scientific assistant stack:

- LM Studio runs natively on Windows and serves the chat LLM through an OpenAI-compatible API.
- Docker Engine runs inside WSL/Linux and serves Open WebUI, document parsing, embeddings, reranking, and MCP tools.
- Open WebUI is the user-facing web UI and multi-user layer.

This repository is intentionally scripts-first. It should be possible to clone it on a Windows Server, run one setup script, edit `.env`, and operate the stack without Codex.

## Architecture

```text
Windows Server
  LM Studio native app
  OpenAI-compatible API: http://<server-ip>:1234/v1

WSL2 Debian or Ubuntu
  Native Docker Engine

Docker compose network
  open-webui  -> http://infinity:7997        embeddings and rerank
  open-webui  -> http://mineru:8000          PDF parsing/OCR
  open-webui  -> http://mcpo:8001/...        MCP tools converted to OpenAPI
  open-webui  -> http://host.docker.internal:1234/v1  LM Studio chat model
```

Docker service names such as `infinity`, `mineru`, and `mcpo` are internal DNS names inside the compose network. They are not public DNS names.

## Components

`open-webui`
: Web interface, users, chats, documents, RAG configuration, tool servers. This is the only service normally exposed to users on the LAN.

`infinity`
: Embedding/reranking inference server. It is not a chat LLM. Here it loads `BAAI/bge-m3` for embeddings and `BAAI/bge-reranker-v2-m3` for rerank. Open WebUI calls `http://infinity:7997` and `http://infinity:7997/rerank` inside Docker.

`mineru`
: PDF parsing/OCR/content extraction service. It runs MinerU API in `pipeline` mode by default because that is the stable local/server default for scientific PDFs.

`mcpo`
: Converts MCP servers into OpenAPI tool servers that Open WebUI can use. The configured tools are `paper_search`, `citecheck`, `sequential_thinking`, `memory`, and `sympy`.

`LM Studio`
: The chat model server. It is deliberately outside Docker because the project is targeting Windows Server with LM Studio as the model host.

## LM Studio Settings

In LM Studio, open `Developer -> Local Server`.

Required:

1. Set `Server Port` to `1234`.
2. Enable `Serve on Local Network`.
3. Load a chat model.
4. Start the local server.

Recommended on a real LAN server:

1. Enable `Require Authentication`.
2. Click `Manage Tokens` and create an API token.
3. Put that token into `.env` as `LMSTUDIO_API_KEY=...`.
4. Restrict Windows Firewall so only trusted machines can reach port `1234`.

Optional:

- `Just-in-Time Model Loading`: useful if LM Studio should auto-load models by request.
- `Auto unload unused JIT loaded models`: useful on a shared server, but can surprise users if the first request after idle is slow.
- `Only Keep Last JIT Loaded Model`: disable this if you want to keep multiple loaded models, for example one writing model and one coding model, and you have enough VRAM.

Do not rely on LM Studio MCP settings for this stack. MCP is wired through `mcpo` into Open WebUI. Adding `mcpServers` in LM Studio would make tools available to LM Studio clients, not to Open WebUI RAG/tool workflows. Keeping tools in Open WebUI avoids two competing tool registries.

## Models

The scripts do not hard-code the chat LLM. Open WebUI asks LM Studio for whatever model is loaded there.

For local light testing, load a small model in LM Studio and optionally set:

```env
EXPECTED_LMSTUDIO_MODEL=gemma
```

For the production server, load the desired GLM model in LM Studio and set a substring that appears in LM Studio's model id:

```env
EXPECTED_LMSTUDIO_MODEL=glm
```

Do not put an exact GLM 5.2 id here until you have verified the exact model id shown by LM Studio on that server. Model names and quantization suffixes vary by provider/file.

## Ports

Defaults from `.env.example`:

```text
3000  Open WebUI  WEBUI_BIND=0.0.0.0  visible on LAN
1234  LM Studio   configured in LM Studio, not Docker
7997  Infinity    INTERNAL_BIND=127.0.0.1 by default
8000  MinerU      INTERNAL_BIND=127.0.0.1 by default
8001  mcpo        INTERNAL_BIND=127.0.0.1 by default
```

On a large LAN:

- Keep `INTERNAL_BIND=127.0.0.1` unless you intentionally need direct access to MinerU/Infinity/mcpo.
- Expose `WEBUI_PORT=3000` only to trusted users or behind VPN/reverse proxy.
- If LM Studio must be used directly from VS Code or other clients, expose `1234` only to trusted machines and enable `Require Authentication`.

## How WSL Sees LM Studio

`localhost` inside WSL is not the same process namespace as native Windows apps in all cases. The startup scripts detect the WSL default gateway:

```bash
ip route | awk '/^default / { print $3; exit }'
```

That is why you may see addresses like `172.26.80.1`. It is the Windows host as seen from WSL NAT, not a random public IP.

For containers, `start-all.sh` maps `host.docker.internal` to that Windows gateway IP when running native Docker Engine inside WSL. Then Open WebUI can call:

```text
http://host.docker.internal:1234/v1
```

and reach native LM Studio on Windows.

## Setup On Windows Server

Run in elevated PowerShell if WSL is not installed:

```powershell
wsl --install -d Debian
wsl --update
```

Install current NVIDIA Windows driver with WSL CUDA support.

Clone the repository:

```powershell
cd C:\Users\Public
git clone https://github.com/maximmeshkov/vsuLLMScripts.git
cd .\vsuLLMScripts
```

Run interactive setup:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup_all.ps1
```

The setup script:

- asks which WSL distro to use;
- optionally keeps WSL alive while containers run;
- syncs the project into WSL, usually `~/sci-assistant`;
- runs Linux-side setup;
- can install/start native Docker Engine inside WSL;
- can configure NVIDIA Container Toolkit if Docker cannot see GPUs;
- can start the stack.

## Start

From Windows PowerShell:

```powershell
cd C:\Users\Public\vsuLLMScripts
powershell -ExecutionPolicy Bypass -File .\start-all.ps1 -Distro Debian
```

Fast restart without rebuilding images:

```powershell
powershell -ExecutionPolicy Bypass -File .\start-all.ps1 -Distro Debian -NoBuild
```

From WSL:

```bash
cd ~/sci-assistant
./start-all.sh
```

Expected final message:

```text
ALL CORE SERVICES UP. Open WebUI: http://localhost:3000
```

## Stop

From Windows PowerShell:

```powershell
cd C:\Users\Public\vsuLLMScripts
powershell -ExecutionPolicy Bypass -File .\stop_all.ps1 -Distro Debian
```

Choose:

- `1` stop containers only;
- `2` remove containers/network, keep data;
- `3` remove containers/network/compose volumes;
- `7` stop WSL keepalive.

From WSL:

```bash
cd ~/sci-assistant
./stop-all.sh --stop
```

## Diagnostics

Quick check:

```powershell
wsl -d Debian -- bash -lc "cd ~/sci-assistant && ./doctor.sh"
```

Deep check:

```powershell
wsl -d Debian -- bash -lc "cd ~/sci-assistant && ./doctor.sh --deep"
```

The deep check tests:

- LM Studio `/v1/models`;
- LM Studio chat completion;
- Infinity embeddings;
- Infinity rerank;
- MinerU PDF parse.

## Live Logs

Default: follow all compose services in this stack.

```powershell
powershell -ExecutionPolicy Bypass -File .\watch_logs.ps1 -Distro Debian
```

This follows:

```text
open-webui mineru infinity mcpo
```

Selected services:

```powershell
powershell -ExecutionPolicy Bypass -File .\watch_logs.ps1 -Distro Debian -Services mineru,infinity
powershell -ExecutionPolicy Bypass -File .\watch_logs.ps1 -Distro Debian -Services open-webui
```

The log window is only a viewer. `Ctrl+C` stops log following, not the containers.

## Multi-User Open WebUI

Open WebUI is the multi-user layer.

First-run friendly default in `.env.example`:

```env
ENABLE_SIGNUP=true
DEFAULT_USER_ROLE=pending
```

For production on a large LAN, avoid a race for the first admin account. Before first start, set:

```env
WEBUI_ADMIN_EMAIL=admin@example.local
WEBUI_ADMIN_PASSWORD=replace-with-long-password
WEBUI_ADMIN_NAME=Admin
```

After the admin exists, set:

```env
ENABLE_SIGNUP=false
```

Do not commit real admin credentials.

After the first admin exists, manage users in Open WebUI Admin Panel. Exact UI labels can change between Open WebUI builds, but the relevant area is the admin users/settings section.

## Access From VS Code Or Other Clients

There are two separate APIs:

Open WebUI:

```text
http://<server-ip>:3000
```

LM Studio OpenAI-compatible API:

```text
http://<server-ip>:1234/v1
```

For VS Code extensions or coding agents that accept an OpenAI-compatible endpoint:

```text
Base URL: http://<server-ip>:1234/v1
API key: LM Studio token if Require Authentication is enabled; otherwise any placeholder accepted by the client
Model: exact model id shown by LM Studio
```

If you want a second coding model, load it in LM Studio. If both writing and coding models must stay loaded, disable `Only Keep Last JIT Loaded Model` in LM Studio and make sure VRAM is sufficient.

## Cleanup Failed Or Old Files

Dry-run failed files:

```powershell
powershell -ExecutionPolicy Bypass -File .\cleanup_openwebui_files.ps1 -Distro Debian -Mode failed
```

Delete failed files:

```powershell
powershell -ExecutionPolicy Bypass -File .\cleanup_openwebui_files.ps1 -Distro Debian -Mode failed -Apply -Yes
```

Keep only one Knowledge base, for example `rfBooks`, and delete all other global Files entries:

```powershell
powershell -ExecutionPolicy Bypass -File .\cleanup_openwebui_files.ps1 -Distro Debian -Mode not-in-knowledge-name -KnowledgeName rfBooks -Apply -Yes
```

The cleanup uses Open WebUI `DELETE /api/v1/files/{id}`. Do not manually delete Chroma rows unless you are doing database recovery.

## Important `.env` Settings

Core:

```env
WEBUI_BIND=0.0.0.0
WEBUI_PORT=3000
INTERNAL_BIND=127.0.0.1
LMSTUDIO_BASE_URL=http://host.docker.internal:1234/v1
LMSTUDIO_API_KEY=lm-studio
```

RAG:

```env
INFINITY_EMBED_MODEL=BAAI/bge-m3
INFINITY_RERANK_MODEL=BAAI/bge-reranker-v2-m3
RAG_EMBEDDING_BATCH_SIZE=1
RAG_EMBEDDING_CONCURRENT_REQUESTS=1
ENABLE_RAG_HYBRID_SEARCH=true
```

For a powerful server, raise embedding concurrency only after a real folder-upload test:

```env
RAG_EMBEDDING_CONCURRENT_REQUESTS=2
RAG_EMBEDDING_BATCH_SIZE=4
```

Do not set it to unlimited for shared use without measuring file upload behavior.

MinerU:

```env
MINERU_PARAMS={"backend":"pipeline","lang_list":["east_slavic"],"parse_method":"auto","formula_enable":true,"table_enable":true,"return_md":true}
```

`pipeline` is the production-default here. Do not switch to `hybrid-engine` unless you have explicitly tested VRAM and stability.

## Reference Links

- LM Studio local server and OpenAI-compatible API: <https://lmstudio.ai/docs/app/api>
- LM Studio MCP support: <https://lmstudio.ai/docs/app/mcp>
- Open WebUI environment variables: <https://docs.openwebui.com/getting-started/env-configuration/>
- Infinity embedding/rerank server: <https://github.com/michaelfeil/infinity>
- MinerU: <https://github.com/opendatalab/MinerU>
- mcpo: <https://github.com/open-webui/mcpo>
