# Научный ассистент — RUNBOOK (финальная сборка)

Локальный научный RAG-ассистент: поиск+суммаризация статей, помощь с текстами, точная математика, память.
Всё в Docker (один compose), **кроме чат-модели** (LM Studio — нативное Windows-приложение).

```
Браузер ─► Open WebUI (:3000, docker)
              ├─ /v1/chat ─────────────► LM Studio (:1234, НАТИВНО) — чат-модель на GPU
              ├─ embeddings + rerank ──► Infinity (:7997, docker, GPU)  bge-m3 + bge-reranker-v2-m3
              ├─ Content Extraction ───► MinerU  (:8000, docker, GPU)   парсинг PDF (pipeline)
              └─ External Tools ───────► mcpo    (:8001, docker)  5 MCP:
                                          paper_search, citecheck, sequential_thinking, memory, sympy
```

Файлы проекта: `C:\Users\maxim\sci-assistant\`.

---

## 0. Предусловия (один раз)
- **NVIDIA-драйвер** + **Docker Desktop** (WSL2-backend). GPU-в-Docker проверен: `docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi` показывает карту.
- **LM Studio** (для чат-модели).

## 1. LM Studio (только чат)
- Загрузить **чат-модель** (дома: `gemma-4-12B-it`/Qwen3-14B; сервер: большая, см. §7).
- Developer → **Start Server** (:1234).
- ⚠️ Эмбеддер в LM Studio **больше НЕ нужен** — его делает Infinity. Если был загружен — Eject (освобождает VRAM).

## 2. Поднять Docker-стек (одна команда)
```powershell
cd C:\Users\maxim\sci-assistant
powershell -ExecutionPolicy Bypass -File .\start-all.ps1
```
Поднимает Open WebUI + Infinity + mcpo + MinerU и делает health-check всех пяти точек (включая LM Studio).
Альтернатива: `docker compose up -d`.

Первый старт: Infinity и MinerU грузят модели (Infinity качает bge-m3/reranker в том `infinity-cache`; модели MinerU вшиты в образ).

## 3. Настройка Open WebUI (один раз — и ОБЯЗАТЕЛЬНО заново на новом сервере)
⚠️ **Все настройки ниже хранятся в `./data`, которой НЕТ в server-zip** (и которая стирается при чистом стейте).
На свежем сервере / после вайпа `data` **весь §3 надо пройти руками заново**: первый аккаунт-админ,
Connections, embeddings/reranker (External → Infinity), Content Extraction (MinerU + `{"backend":"pipeline"}`),
MCP-инструменты (Integrations → 5 серверов `http://mcpo:8001/...`), Code Execution, RAG-настройки (Top K/Hybrid/threshold),
Workspace-пресеты. Конфиг-файлы дают только сервисы; настройки UI — руками.

Открыть http://localhost:3000 → первый аккаунт = админ. Admin → Settings:

**Connections** — чат уже на LM Studio (через env: `host.docker.internal:1234`).

**Documents:**
- Content Extraction = **MinerU**, режим **local**, URL **`http://mineru:8000`**, Parameters **`{"backend":"pipeline"}`**, ключ пустой.
- Эмбеддер уже на Infinity (env: `http://infinity:7997`, модель `BAAI/bge-m3`).
- **Full Context Mode = OFF.**
- **Top K = 10**, **Hybrid Search = ON**, **Reranking Engine = External**, URL **`http://infinity:7997/rerank`**, **Relevance Threshold ≈ 0.4**.

**Integrations → Manage Tool Servers** (тип OpenAPI, URL, ключ `change-me-secret`):
- `http://mcpo:8001/paper_search`  ·  `/citecheck`  ·  `/sequential_thinking`  ·  `/memory`  ·  `/sympy`

**Code Execution** — включить (числовая математика: NumPy/SciPy; symbolic — через sympy-MCP).

> Меняли эмбеддер/Content Extraction → нажать **«Пересоздать»** (реиндекс баз).

## 4. «Проекты» (чтобы инструменты/базы не сбрасывались)
Workspace → **Models** → создать пресет (системный промпт + привязанные Tools + Knowledge). Выбираешь его в чате — всё активно само. По пресету на задачу: «Обзор литературы», «Письмо», «Расчёты».
Системный промпт (правила роутинга + grounding + «математику через Python/sympy, факты в memory») — см. отдельную заметку/историю.

## 5. Загрузка статей
Workspace → Knowledge → база → перетащить PDF (батчами). MinerU парсит (pipeline, GPU). Для `.djvu` — сначала конвертировать в PDF (`ddjvu -format=pdf`), затем залить.
«Обзор всего корпуса» — это НЕ RAG (он тянет top-k), а отдельная пакетная суммаризация по файлам.

## 6. Бэкап
- **`./data`** — всё состояние Open WebUI (аккаунты, чаты, ChromaDB, загруженные файлы).
- **`./mcp-data/memory.jsonl`** — память ассистента.
Остановить (`docker compose stop`), скопировать папки, запустить.

## 7. Перенос на сервер (Windows Server, мощные GPU)
- Скопировать папку `sci-assistant`, `docker compose up -d --build`.
- **Чат-модель:** большая, по критерию **tool-calling + длинный контекст + RU/EN** (не «самая жирная»). FP8 при изобилии VRAM (не INT4). Кандидаты mid-2026: Qwen3.5-397B / GLM-5.2 / Kimi K2.6. Свериться с Berkeley Function-Calling Leaderboard + свой eval.
  - На сервере чат тоже можно увести в Docker (**vLLM**, GPU) — тогда LM Studio не нужен вовсе.
- **Эмбеддер/реранкер:** в Infinity можно крупнее (Qwen3-Embedding-8B, bge-reranker-v2-gemma) — VRAM хватит.
- На большом GPU всё (чат+Infinity+MinerU) живёт одновременно без тесноты.

## 8. Устаревшее (можно удалить — заменено контейнерами)
`setup-mcp.ps1`, `mcp.json` (нативный), `mineru-env\`, `infinity-env\`, `pqa-env\`, нативный `sympy-mcp\`.
(Актуальны: `docker-compose.yml`, `Dockerfile.mcpo`, `Dockerfile.mineru`, `mcp.docker.json`, `.dockerignore`, `start-all.ps1`, `mcp.optional.md`.)

## 9. Troubleshooting
| Симптом | Причина / фикс |
|---|---|
| Сервис [DOWN] в start-all | `docker compose logs <service>`; LM Studio запусти вручную |
| MinerU CUDA OOM (на сервере/нагрузке) | проверь VRAM; для MinerU нужен backend `pipeline` (не vlm) |
| RAG «1 источник» | обзорный вопрос (норм) ИЛИ Top K мал / Hybrid off / порог высок |
| Reranker медленный | он на Infinity-GPU (External) — не на CPU Open WebUI |
| Инструменты сбрасываются в чате | привязать к Model-пресету (§4), не тыкать тумблеры |
| Tool-calling капризит | слабая модель; на сервере надёжнее; в системный промпт правила роутинга |
| `database is locked` | SQLite на Windows-bind (`./data`); при проблемах — named volume |

## Контейнеры/образы
`docker-compose.yml` → open-webui, infinity (michaelf34/infinity), mcpo (`Dockerfile.mcpo`), mineru (`Dockerfile.mineru`, ~43GB с моделями).
Health/проверки: Open WebUI :3000, Infinity :7997/health, mcpo :8001/docs, MinerU :8000/docs.
