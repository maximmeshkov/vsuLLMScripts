# Server Deployment Plan

This is the working plan for moving the stack from local WSL testing to the production Windows Server.

## Current Decisions

1. Runtime shape is fixed:
   - LM Studio runs natively on Windows.
   - Docker Engine runs natively inside WSL/Linux.
   - Docker Desktop is not the target runtime.

2. Open WebUI is the user-facing UI and multi-user layer.

3. LM Studio is the chat-model API for Open WebUI. MCP tools are configured through `mcpo` for Open WebUI. MCP can also be configured in LM Studio separately if LM Studio itself, or an API client that supports LM Studio MCP, should use tools.

4. MCP tools are exposed through `mcpo` into Open WebUI:
   - `paper_search`
   - `citecheck`
   - `sequential_thinking`
   - `memory`
   - `sympy`
   - `visual_search` through the separate `image-rag` OpenAPI service

   Optional LM Studio MCP is a separate tool registry. Do not assume a VS Code OpenAI-compatible client automatically receives LM Studio MCP tools unless that client explicitly supports them.

5. MinerU production default is:

   ```json
   {"backend":"pipeline","lang_list":["east_slavic"],"parse_method":"auto","formula_enable":true,"table_enable":true,"return_md":true}
   ```

   Do not silently switch this to `hybrid-engine`.

6. Local conservative embedding limits stay in place until the next test:

   ```env
   RAG_EMBEDDING_BATCH_SIZE=1
   RAG_EMBEDDING_CONCURRENT_REQUESTS=1
   ```

7. Visual/image RAG is a separate tool server:

   ```env
   IMAGE_RAG_CLIP_MODEL=clip-ViT-B-32
   IMAGE_RAG_RENDER_DPI=144
   IMAGE_RAG_MAX_PAGES_PER_PDF=80
   ```

   It indexes rendered PDF pages and embedded raster images under `./image-rag-data`. It does not yet crop individual semantic figures out of pages.

## Morning Local Retest

1. Start LM Studio.
2. Load a small test model.
3. Enable in LM Studio:
   - `Serve on Local Network`
   - optional local testing: `Require Authentication` off
4. Start stack:

   ```powershell
   cd C:\Users\maxim\sci-assistant
   powershell -ExecutionPolicy Bypass -File .\start-all.ps1 -Distro Debian -NoBuild
   ```

5. Run:

   ```powershell
   wsl -d Debian -- bash -lc "cd ~/sci-assistant && ./doctor.sh --deep"
   ```

6. Open logs:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\watch_logs.ps1 -Distro Debian
   ```

7. Upload a small folder into one Open WebUI Knowledge base.
8. Check:
   - Open WebUI file list has no unexpected failed items.
   - `doctor.sh --deep` still passes.
   - logs have no `Too many open files`, `Task execution failed`, `CUDA error`.

## Production Server Setup

1. Install/update WSL:

   ```powershell
   wsl --install -d Debian
   wsl --update
   ```

2. Install NVIDIA Windows driver with WSL CUDA support.

3. Install LM Studio on Windows Server.

4. Clone repo:

   ```powershell
   cd C:\Users\Public
   git clone https://github.com/maximmeshkov/vsuLLMScripts.git
   cd .\vsuLLMScripts
   ```

5. Run setup:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\setup_all.ps1
   ```

6. Edit server `.env` inside WSL or let `start-all.sh` create it first, then edit:

   ```powershell
   wsl -d Debian -- nano ~/sci-assistant/.env
   ```

## Production LM Studio Checklist

Required:

- Port: `1234`
- `Serve on Local Network`: enabled
- Load target model
- Server status: running

Recommended for large LAN:

- `Require Authentication`: enabled
- Create token in `Manage Tokens`
- Put token in `.env`:

  ```env
  LMSTUDIO_API_KEY=replace-with-token
  ```

- Restrict Windows Firewall access to port `1234`.

For multiple loaded models:

- Disable `Only Keep Last JIT Loaded Model`.
- Reconsider `Auto unload unused JIT loaded models` depending on user expectations.
- Keep enough VRAM free for embeddings/OCR if they share GPUs.

## Production Model Plan

Target writing model: GLM 5.2 if it is available and verified in LM Studio on the server.

Do not hard-code an exact GLM model id until LM Studio shows it. Set a loose check first:

```env
EXPECTED_LMSTUDIO_MODEL=glm
```

If the exact model id is known later, replace it with a stricter substring.

## Multi-User Plan

Open WebUI handles users.

First-run friendly default:

```env
ENABLE_SIGNUP=true
DEFAULT_USER_ROLE=pending
```

Production server option, preferred on a large LAN:

Set before first start:

```env
WEBUI_ADMIN_EMAIL=admin@example.local
WEBUI_ADMIN_PASSWORD=replace-with-long-password
WEBUI_ADMIN_NAME=Admin
```

After admin exists:

```env
ENABLE_SIGNUP=false
```

After admin exists, create/approve users through Open WebUI Admin Panel.

## Port Exposure Plan

Default intended exposure:

```text
3000/tcp  Open WebUI  LAN users
1234/tcp  LM Studio   only trusted clients, preferably with auth
7997/tcp  Infinity    localhost only
8000/tcp  MinerU      localhost only
8001/tcp  mcpo        localhost only
8010/tcp  image-rag   localhost only
```

Do not expose `7997`, `8000`, `8001`, or `8010` to the whole LAN unless there is a specific operational reason.

## VS Code / Coding Client Access

If a VS Code extension supports OpenAI-compatible endpoints:

```text
Base URL: http://<server-ip>:1234/v1
API key: LM Studio token
Model: exact model id shown by LM Studio
```

This talks directly to LM Studio, not Open WebUI.

If a client must use Open WebUI instead, use Open WebUI API keys and its API surface separately. Do not assume every OpenAI-compatible client supports Open WebUI identically.

If the coding client needs MCP tools, use one of these explicit paths:

1. Configure MCP directly in the VS Code/coding client if it supports MCP.
2. Configure MCP in LM Studio and enable LM Studio's MCP API behavior if that specific client supports it.
3. Use Open WebUI's tool layer from the browser UI.

These are not interchangeable by default.

## Items To Revisit After Server Test

1. Raise embedding concurrency gradually:

   ```env
   RAG_EMBEDDING_CONCURRENT_REQUESTS=2
   RAG_EMBEDDING_BATCH_SIZE=4
   ```

2. Check whether MinerU should use one GPU and LM Studio another.

3. Decide whether LM Studio should expose multiple loaded models for coding and writing.

4. Add backup script for:
   - `~/sci-assistant/data`
   - `~/sci-assistant/mcp-data`
   - `~/sci-assistant/papers`
   - `sci-assistant_infinity-cache` Docker volume

5. Decide whether Open WebUI should sit behind a reverse proxy/TLS.
