# Server launch checklist

This file is the no-Codex path for launching the scientific assistant on Windows Server with WSL2 and native Docker Engine inside WSL.

## 0. Architecture

Use this layout:

```text
Windows Server
  LM Studio native Windows, OpenAI-compatible API on port 1234
WSL2 Debian or Ubuntu
  native Docker Engine
  Open WebUI on port 3000
  Infinity on port 7997
  mcpo on port 8001
  MinerU on port 8000
```

Do not target Docker Desktop as the server runtime. The scripts reject Docker Desktop backend in WSL.

## 1. Windows prerequisites

Run in elevated Windows PowerShell:

```powershell
wsl --install -d Debian
wsl --update
```

Install current NVIDIA Windows driver with WSL CUDA support.

Install LM Studio on Windows. In LM Studio:

1. Open `Developer` -> `Local Server`.
2. Set port `1234`.
3. Enable `Serve on Local Network`.
4. Load the chosen chat model.
5. Start the server.

If Windows Firewall asks, allow local network access for port `1234`.

## 2. Copy project to the server

Put this folder on the server, for example:

```powershell
C:\Users\maxim\sci-assistant
```

Then run:

```powershell
cd C:\Users\maxim\sci-assistant
powershell -ExecutionPolicy Bypass -File .\setup_all.ps1
```

Choose the WSL distro. Let it sync the project into WSL at `~/sci-assistant`.

The sync copies config/scripts/build files only. It intentionally skips runtime folders:
`.env`, `data/`, `mcp-data/`, `papers/`, `.git`, `.venv`, `venv`, `node_modules`.
The server-side `.env` is created from `.env.example` inside WSL and keeps its own secrets.

## 3. First setup inside WSL

`setup_all.ps1` runs `setup_all.sh` inside WSL. If you need to do it manually:

```powershell
wsl -d Debian
```

```bash
cd ~/sci-assistant
./setup_all.sh
```

Accept Docker Engine installation if Docker is missing.

Accept NVIDIA Container Toolkit setup if Docker cannot see GPUs.

## 4. Start

From Windows PowerShell:

```powershell
cd C:\Users\maxim\sci-assistant
powershell -ExecutionPolicy Bypass -File .\start-all.ps1
```

`start-all.ps1` selects the WSL distro, starts a hidden WSL keepalive process, and then runs `./start-all.sh` inside WSL. This matters on Windows/WSL because native Docker containers stop when the WSL distro exits.

First-time setup still uses:

```powershell
cd C:\Users\maxim\sci-assistant
powershell -ExecutionPolicy Bypass -File .\setup_all.ps1
```

Or start directly from an already-open WSL shell:

```bash
cd ~/sci-assistant
./start-all.sh
```

For a faster restart without rebuilding images:

From Windows PowerShell:

```powershell
cd C:\Users\maxim\sci-assistant
powershell -ExecutionPolicy Bypass -File .\start-all.ps1 -NoBuild
```

From WSL:

```bash
cd ~/sci-assistant
./start-all.sh --no-build
```

Expected final line:

```text
ALL CORE SERVICES UP. Open WebUI: http://localhost:3000
```

To watch live processing in a visible Windows window:

```powershell
cd C:\Users\maxim\sci-assistant
powershell -ExecutionPolicy Bypass -File .\watch_logs.ps1 -Distro Debian
```

This follows `open-webui`, `mineru`, `infinity`, and `mcpo` logs. Close the window or press `Ctrl+C` when done.

To watch only selected services:

```powershell
powershell -ExecutionPolicy Bypass -File .\watch_logs.ps1 -Distro Debian -Services mineru,infinity
powershell -ExecutionPolicy Bypass -File .\watch_logs.ps1 -Distro Debian -Services open-webui
```

## 5. Verify without Codex

Quick check:

```bash
cd ~/sci-assistant
./doctor.sh
```

Full functional check:

```bash
cd ~/sci-assistant
./doctor.sh --deep
```

From Windows PowerShell, run the same check through WSL:

```powershell
wsl -d Debian -- bash -lc "cd ~/sci-assistant && ./doctor.sh --deep"
```

GPU container check:

```bash
cd ~/sci-assistant
./doctor.sh --gpu-smoke
```

The deep check must pass:

```text
LM Studio chat completion
Infinity embeddings
Infinity rerank
MinerU pipeline PDF parse
```

## 6. Open WebUI expected settings

Open:

```text
http://localhost:3000
```

Admin settings should show:

```text
Documents:
  Content Extraction Engine: MinerU
  API Mode: local
  API URL: http://mineru:8000
  Parameters:
    backend: pipeline
    lang_list: east_slavic

Embedding:
  Engine: OpenAI
  Base URL: http://infinity:7997
  Model: BAAI/bge-m3

Retrieval:
  Hybrid Search: enabled
  Reranking Batch Size: 32
  Top K: 3

Integrations:
  paper_search: enabled
  citecheck: enabled
  sequential_thinking: enabled
  memory: enabled
  sympy: enabled
```

Some rerank fields are not visible in this Open WebUI build. They are set through environment variables:

```text
RAG_RERANKING_ENGINE=external
RAG_EXTERNAL_RERANKER_URL=http://infinity:7997/rerank
```

## 7. Stop

From Windows:

```powershell
cd C:\Users\maxim\sci-assistant
powershell -ExecutionPolicy Bypass -File .\stop_all.ps1
```

From WSL:

```bash
cd ~/sci-assistant
./stop-all.sh --stop
```

Use `--down` to remove containers and network while keeping data.

Use `--volumes` only when you intentionally want to remove compose volumes/cache.

## 8. Troubleshooting map

LM Studio not reachable:

```text
Enable Serve on Local Network in LM Studio.
Check Windows Firewall port 1234.
Run ./doctor.sh and inspect the printed LM Studio health URL.
```

Docker Desktop backend detected:

```text
Start native Docker Engine inside WSL:
sudo service docker start
export DOCKER_HOST=unix:///var/run/docker.sock
```

GPU smoke fails:

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo service docker restart
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

MinerU upload fails with `Engine core initialization failed`:

```text
This usually means MinerU used hybrid/vLLM backend and there is not enough free VRAM.
For local testing keep MinerU params on backend=pipeline and lang_list=east_slavic.
Also check that the running open-webui container received valid JSON:
  docker compose --env-file .env exec -T open-webui printenv MINERU_PARAMS
It must look like:
  {"backend":"pipeline","lang_list":["east_slavic"],"parse_method":"auto","formula_enable":true,"table_enable":true,"return_md":true}
If it looks like {backend:pipeline,...}, recreate open-webui with:
  ./start-all.sh --no-build
Run ./doctor.sh --deep and require MinerU pipeline PDF parse to pass.
```

Folder upload shows only a few documents:

```text
Check Open WebUI logs for "Too many open files" during embeddings.
The local default is intentionally conservative:
  RAG_EMBEDDING_BATCH_SIZE=1
  RAG_EMBEDDING_CONCURRENT_REQUESTS=1
Run ./doctor.sh --deep and require:
  open-webui embedding batch/concurrency limits are conservative
Already failed file rows do not repair themselves; delete/reupload or reprocess them.
```

Open a visible live-log window from PowerShell:

```powershell
cd C:\Users\maxim\sci-assistant
powershell -ExecutionPolicy Bypass -File .\watch_logs.ps1 -Distro Debian
```

Count indexed vs failed files inside Open WebUI:

```powershell
@'
import sqlite3, json, collections
con = sqlite3.connect('/app/backend/data/webui.db')
con.row_factory = sqlite3.Row
rows = con.execute('select meta, data from file').fetchall()
by_status = collections.Counter()
by_index = collections.Counter()
for row in rows:
    meta = json.loads(row['meta']) if row['meta'] else {}
    data = json.loads(row['data']) if row['data'] else {}
    by_status[data.get('status')] += 1
    by_index['indexed' if meta.get('collection_name') else 'not_indexed'] += 1
print('by_status:', dict(by_status))
print('by_index:', dict(by_index))
'@ | wsl -d Debian -- docker exec -i open-webui python -
```

If a file is already uploaded but failed, use the Open WebUI API to reprocess it into a knowledge base. Replace `KNOWLEDGE_ID` and `FILE_ID`:

```powershell
@'
set -euo pipefail
KNOWLEDGE_ID='replace-with-knowledge-id'
FILE_ID='replace-with-file-id'
USER_ID=$(docker exec open-webui python - <<'PY'
import sqlite3
con = sqlite3.connect('/app/backend/data/webui.db')
row = con.execute("select id from user where role='admin' order by created_at limit 1").fetchone()
print(row[0])
PY
)
TOKEN=$(docker exec open-webui python -c "from open_webui.utils.auth import create_token; print(create_token({'id':'$USER_ID'}))")
curl -sS -f \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"file_id\":\"$FILE_ID\"}" \
  "http://127.0.0.1:3000/api/v1/knowledge/$KNOWLEDGE_ID/file/add"
'@ | wsl -d Debian -- bash -s
```

Delete failed/global Open WebUI files safely through the API, not by manually editing Chroma.

Dry-run failed files:

```powershell
cd C:\Users\maxim\sci-assistant
powershell -ExecutionPolicy Bypass -File .\cleanup_openwebui_files.ps1 -Distro Debian -Mode failed
```

Actually delete failed files:

```powershell
powershell -ExecutionPolicy Bypass -File .\cleanup_openwebui_files.ps1 -Distro Debian -Mode failed -Apply -Yes
```

Dry-run everything except one Knowledge base, for example keep only `rfBooks`:

```powershell
powershell -ExecutionPolicy Bypass -File .\cleanup_openwebui_files.ps1 -Distro Debian -Mode not-in-knowledge-name -KnowledgeName rfBooks
```

Actually keep only `rfBooks` and delete all other global Files entries:

```powershell
powershell -ExecutionPolicy Bypass -File .\cleanup_openwebui_files.ps1 -Distro Debian -Mode not-in-knowledge-name -KnowledgeName rfBooks -Apply -Yes
```

Rerank seems unused:

```text
Hybrid Search must be enabled.
Infinity /rerank existing is not enough.
Run ./doctor.sh --deep and require Infinity rerank to pass.
```

Tool servers missing:

```text
Check Admin Panel -> Settings -> Integrations.
Run docker compose --env-file .env config and search TOOL_SERVER_CONNECTIONS.
```

## 9. Backups

Back up:

```text
~/sci-assistant/data
~/sci-assistant/mcp-data
~/sci-assistant/papers
docker volume sci-assistant_infinity-cache
```

Do not publish `.env`; it contains keys.
