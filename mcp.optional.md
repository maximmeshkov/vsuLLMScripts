# Опциональные MCP-серверы — шпаргалка «у стойки»

JSON не поддерживает комментарии, поэтому держу запасные серверы здесь.
Чтобы добавить — скопируй нужный блок ВНУТРЬ "mcpServers" в `mcp.json` (не забудь запятые между блоками).

## Активные сейчас (в mcp.json)
- paper_search   — поиск статей (arXiv/PubMed/Semantic Scholar/OpenAlex)
- citecheck       — проверка библиографии
- sequential_thinking — пошаговое планирование

## Запасные (вставляй по необходимости)

# Общий веб-фетч (модель тянет страницу по URL) — verified, официальный
"fetch": {
  "command": "uvx",
  "args": ["mcp-server-fetch"]
},

# Веб-поиск без SearXNG (нужен ключ Brave) — verified, официальный
"brave_search": {
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-brave-search"],
  "env": { "BRAVE_API_KEY": "твой-ключ" }
},

# arXiv: поиск + скачивание в markdown — уточни точную команду в репо blazickjp/arxiv-mcp-server
"arxiv": {
  "command": "uvx",
  "args": ["arxiv-mcp-server"]
},

# Zotero (если вдруг заведёте) — уточни команду в репо 54yyyu/zotero-mcp
"zotero": {
  "command": "uvx",
  "args": ["zotero-mcp"]
},

# Доступ к локальной ФС (модель читает файлы из папки) — verified, официальный
"filesystem": {
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-filesystem", "C:\\Users\\maxim\\papers"]
},

# Точная математика — уже добавлена в mcp.json как "sympy" (sdiehl/sympy-mcp, склонирован в .\sympy-mcp).
# НЕ используй pydantic/mcp-run-python: репо архивировано + дыры в песочнице (escape из Pyodide).

## Подсказки
- uvx → нужен uv (Python). npx → нужен Node.js. Оба ставит setup-mcp.ps1.
- После правки mcp.json перезапусти mcpo.
- Каждый сервер появится в Open WebUI по пути http://host.docker.internal:8000/<имя>.
