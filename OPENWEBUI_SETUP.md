# Open WebUI setup for sci-assistant

This project runs the service containers in WSL/Linux Docker and keeps the chat model in native LM Studio on Windows.

Use these URLs depending on where you type them:

| Place | LM Studio | Infinity | MinerU | mcpo |
| --- | --- | --- | --- | --- |
| Windows browser | `http://127.0.0.1:1234/v1` | `http://127.0.0.1:7997` | `http://127.0.0.1:8000` | `http://127.0.0.1:8001` |
| Inside Open WebUI container | `http://host.docker.internal:1234/v1` | `http://infinity:7997` | `http://mineru:8000` | `http://mcpo:8001` |

`infinity`, `mineru`, and `mcpo` are Docker Compose service names. They are valid from one container to another, not from the Windows browser.

## LM Studio

In LM Studio:

1. Open `Developer` -> `Local Server`.
2. Load the chat model.
3. Set `Server Port` to `1234`.
4. Enable `Serve on Local Network`.
5. Keep authentication disabled for local testing, or set the same key in `.env` as `LMSTUDIO_API_KEY`.
6. Start the server.

In Open WebUI:

1. Open `Admin Panel` -> `Settings` -> `Connections`.
2. Add or edit the OpenAI-compatible connection.
3. Base URL: `http://host.docker.internal:1234/v1`.
4. API key: value of `LMSTUDIO_API_KEY` from `.env` (`lm-studio` by default).
5. Save.

## Documents / Embeddings

Open `Admin Panel` -> `Settings` -> `Documents`.

In the Embedding section:

1. Embedding Model Engine: `OpenAI`.
2. Base URL: `http://infinity:7997`.
3. API key: value of `INFINITY_API_KEY` from `.env` (`infinity` by default).
4. Embedding Model: value of `INFINITY_EMBED_MODEL` (`BAAI/bge-m3` by default).
5. Save.

The compose file also sets these Open WebUI environment variables for new installs:

```env
RAG_EMBEDDING_ENGINE=openai
RAG_OPENAI_API_BASE_URL=http://infinity:7997
RAG_EMBEDDING_MODEL=BAAI/bge-m3
```

## Rerank

Rerank is not automatic just because Infinity exposes `/rerank`. Open WebUI must be configured to use an external reranker, and `Hybrid Search` must be enabled because this Open WebUI build routes reranking through the hybrid retrieval path.

The compose file now sets:

```env
ENABLE_RAG_HYBRID_SEARCH=true
ENABLE_RAG_HYBRID_SEARCH_ENRICHED_TEXTS=false
RAG_RERANKING_ENGINE=external
RAG_RERANKING_MODEL=BAAI/bge-reranker-v2-m3
RAG_EXTERNAL_RERANKER_URL=http://infinity:7997/rerank
RAG_EXTERNAL_RERANKER_API_KEY=infinity
RAG_EXTERNAL_RERANKER_TIMEOUT=30
RAG_RERANKING_BATCH_SIZE=32
RAG_TOP_K_RERANKER=3
```

For an existing Open WebUI data directory, verify the UI after restart:

1. Open `Admin Panel` -> `Settings` -> `Documents`.
2. Scroll to `Retrieval`.
3. `Hybrid Search` should be enabled.
4. Scroll to `Reranking` if your build shows those fields.
5. Engine should be `External`.
6. Reranking model should match `INFINITY_RERANK_MODEL`.
7. External reranker URL should be `http://infinity:7997/rerank`.
8. API key should match `INFINITY_API_KEY`.
9. Save and re-index uploaded knowledge after changing embedding/rerank models.

If this exact field is not visible in your current UI build, keep the compose variables above and restart Open WebUI. The backend supports these names; they were verified inside the running container.

## MinerU PDF parsing

MinerU is reachable at `http://mineru:8000` from Open WebUI and at `http://127.0.0.1:8000` from Windows.

The compose file sets Open WebUI to use MinerU for PDF parsing:

```env
CONTENT_EXTRACTION_ENGINE=mineru
MINERU_API_MODE=local
MINERU_API_URL=http://mineru:8000
MINERU_API_TIMEOUT=300
MINERU_FILE_EXTENSIONS=pdf
MINERU_PARAMS={"backend":"pipeline","lang_list":["east_slavic"],"parse_method":"auto","formula_enable":true,"table_enable":true,"return_md":true}
```

Verify in `Admin Panel` -> `Settings` -> `Documents`:

1. `Content Extraction Engine` should be `MinerU`.
2. MinerU mode should be `local` if the UI shows the field.
3. MinerU URL should be `http://mineru:8000` if the UI shows the field.
4. Save after manual changes.

Use `pipeline` for the local test profile. `hybrid-engine`/`vlm-engine` can be more accurate, but they start a vLLM engine and need free VRAM; with LM Studio loaded on a 16 GB GPU they can fail. Open WebUI sends PDFs to MinerU local API endpoint `/file_parse`. Changing the extraction engine affects newly uploaded or re-indexed files, not already indexed chunks.

## MCP tools through mcpo

mcpo is auto-wired into Open WebUI through `TOOL_SERVER_CONNECTIONS` in `docker-compose.yml`.

Open WebUI receives these OpenAPI tool servers:

```text
http://mcpo:8001/paper_search/openapi.json
http://mcpo:8001/citecheck/openapi.json
http://mcpo:8001/sequential_thinking/openapi.json
http://mcpo:8001/memory/openapi.json
http://mcpo:8001/sympy/openapi.json
```

Each connection uses `auth_type: bearer` and the `MCPO_API_KEY` value from `.env`.

For an existing Open WebUI data directory, verify after recreating `open-webui`:

1. Open `Admin Panel` -> `Settings` -> `Tools` or `Functions` / tool server area, depending on your build.
2. Check that the enabled tool servers include `paper_search`, `citecheck`, `sequential_thinking`, `memory`, and `sympy`.
3. If they are missing, add them manually with base URL `http://mcpo:8001/<name>`, OpenAPI path `/openapi.json`, auth type `Bearer`, key from `MCPO_API_KEY`.

If you open the same URLs in the Windows browser, use `http://127.0.0.1:8001/...` instead.