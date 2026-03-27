# LocalAI Stack — Merch Miner Service Requirements

> This document describes what the Merch Miner application expects from the localai-stack.
> Copy this file to your localai-stack repo as `docs/merch-miner-requirements.md`.

## Overview

Merch Miner is a POD Business OS that depends on several services running in the localai-stack. This document covers what needs to be configured, added, or verified.

## Service Requirements

### Already Running (verify configuration)

| Service | Used by | Expected URL (env var) | Port | Notes |
|---------|---------|----------------------|------|-------|
| Supabase PostgreSQL | All features | `host.docker.internal:5432` | 5432 | Django connects via `merch_miner` schema |
| SearXNG | PROJ-6 (Research) | `SEARXNG_BASE_URL` | 8080 | No `/search` suffix in base URL |
| Langfuse | PROJ-6/8 (Observability) | `LANGFUSE_HOST` | 3210 | v3+, web + worker services |
| Redis (Valkey) | Django cache + RQ | Shared or separate | 6379 | Merch Miner also runs its own Redis |

### Needs to be Added

| Service | Used by | Docker Image | Port | Env Var in Merch Miner |
|---------|---------|-------------|------|----------------------|
| **Vane** (Perplexica fork) | PROJ-17 (Web Search) | `itzcrazykns1337/vane:latest` | 3000 (or custom) | `VANE_API_URL` |
| **Crawl4ai** | PROJ-17 (Deep Crawl) | `unclecode/crawl4ai:latest` | 11235 | `CRAWL4AI_API_URL` |

### pgvector Extension (PROJ-15)

The existing Supabase PostgreSQL needs the `pgvector` extension enabled. This is managed via Django migration in Merch Miner, but the extension must be available in the PG image.

- Supabase PG images include pgvector by default (since Supabase 1.x)
- Verify: `SELECT * FROM pg_extension WHERE extname = 'vector';`
- If missing: `CREATE EXTENSION IF NOT EXISTS vector;` (requires superuser)
- Also needed: `CREATE EXTENSION IF NOT EXISTS pg_trgm;` (for full-text trigram search)

---

## Vane (Perplexica) — Setup Details

### What it does
AI-powered search engine. Takes a question, searches via SearXNG, LLM synthesizes answer with cited sources. Merch Miner uses it for in-app web search (PROJ-17 Chat).

### Docker Compose Snippet

```yaml
vane:
  image: itzcrazykns1337/vane:latest
  container_name: vane
  restart: unless-stopped
  ports:
    - "3100:3000"  # Map to 3100 to avoid conflict with Open WebUI on 3000
  environment:
    - PORT=3000
    - SIMILARITY_MEASURE=cosine
  volumes:
    - vane-data:/home/perplexica/data
    - ./vane/config.toml:/home/perplexica/config.toml
  networks:
    - merch_net
  depends_on:
    - searxng
```

### Config File (`vane/config.toml`)

```toml
[GENERAL]
PORT = 3000
SIMILARITY_MEASURE = "cosine"

[API_KEYS]
OPENROUTER = ""  # Set via env or config — Vane needs its own LLM access

[API_ENDPOINTS]
SEARXNG = "http://searxng:8080"  # Internal Docker network URL
OLLAMA = ""  # Leave empty if using OpenRouter only

[CHAT_MODEL]
PROVIDER = "custom_openai"
MODEL = "openai/gpt-4.1-mini"
CUSTOM_OPENAI_API_KEY = ""  # OpenRouter API key
CUSTOM_OPENAI_API_URL = "https://openrouter.ai/api/v1"

[EMBEDDING_MODEL]
PROVIDER = "custom_openai"
MODEL = "openai/text-embedding-3-small"
CUSTOM_OPENAI_API_KEY = ""  # Same OpenRouter API key
CUSTOM_OPENAI_API_URL = "https://openrouter.ai/api/v1"
```

### API Contract (what Merch Miner calls)

```
POST /api/search
Content-Type: application/json

{
  "chatModel": {"provider": "custom_openai", "model": "openai/gpt-4.1-mini"},
  "embeddingModel": {"provider": "custom_openai", "model": "openai/text-embedding-3-small"},
  "optimizationMode": "balanced",  // speed | balanced | quality
  "focusMode": "webSearch",
  "query": "camping trends 2026",
  "history": []  // previous message pairs for follow-up
}

Response: SSE stream (init → sources → response chunks → done)
```

---

## Crawl4ai — Setup Details

### What it does
URL-based deep content extractor. Opens pages in headless Chromium, extracts full content as Markdown. Cannot search — needs concrete URLs. Merch Miner uses it for deep-crawling interesting sources from Vane results.

### Docker Compose Snippet

```yaml
crawl4ai:
  image: unclecode/crawl4ai:latest
  container_name: crawl4ai
  restart: unless-stopped
  ports:
    - "11235:11235"
  environment:
    - MAX_CONCURRENT_TASKS=5
    - CRAWL4AI_API_TOKEN=  # Optional: set for API authentication
  networks:
    - merch_net
```

### API Contract (what Merch Miner calls)

```
POST /crawl
Content-Type: application/json

{
  "urls": ["https://example.com/article"],
  "word_count_threshold": 50,
  "extraction_strategy": "NoExtractionStrategy",
  "chunking_strategy": "RegexChunking"
}

Response:
{
  "results": [{
    "url": "https://example.com/article",
    "html": "...",
    "markdown": "# Article Title\n\nContent...",
    "metadata": {"title": "...", "description": "..."},
    "success": true
  }]
}
```

---

## Network Configuration

Merch Miner and localai-stack need to communicate. Current setup uses external Docker network.

```
localai-stack network: merch_net (or supabase-net)
                │
                ├── supabase-db (port 5432)
                ├── searxng (port 8080)
                ├── langfuse-web (port 3210)
                ├── vane (port 3000 internal)
                ├── crawl4ai (port 11235)
                │
merch-miner stack connects to same network:
                │
                ├── web (Django, port 8000)
                ├── frontend (Vite, port 5173)
                ├── redis (port 6379)
                ├── worker-research
                ├── worker-slogan
                ├── worker-design
                └── worker-agent
```

Merch Miner's `docker-compose.yml` references the external network:
```yaml
networks:
  supabase-net:
    external: true
```

Make sure both stacks share the same network name. Services reference each other by container name (e.g. `http://searxng:8080`, `http://vane:3000`).

---

## Merch Miner Env Vars → localai-stack URLs

| Merch Miner Env Var | Points to | Example Value |
|---------------------|-----------|---------------|
| `DATABASE_URL` | Supabase PG | `postgresql://merch_miner_user:pass@host.docker.internal:5432/postgres` |
| `SEARXNG_BASE_URL` | SearXNG | `http://searxng:8080` |
| `LANGFUSE_HOST` | Langfuse | `https://langfuse.yourdomain.com` |
| `VANE_API_URL` | Vane | `http://vane:3000` |
| `CRAWL4AI_API_URL` | Crawl4ai | `http://crawl4ai:11235` |
| `OPENROUTER_API_KEY` | OpenRouter (shared) | `sk-or-...` |
| `OPENROUTER_BASE_URL` | OpenRouter | `https://openrouter.ai/api/v1` |

---

## Verification Checklist

After setup, verify each service:

- [ ] Supabase PG accessible: `psql -h host.docker.internal -U merch_miner_user -d postgres -c "SELECT 1"`
- [ ] pgvector extension: `SELECT * FROM pg_extension WHERE extname = 'vector';`
- [ ] pg_trgm extension: `SELECT * FROM pg_extension WHERE extname = 'pg_trgm';`
- [ ] SearXNG responds: `curl http://searxng:8080/healthz`
- [ ] Langfuse accessible: `curl https://langfuse.yourdomain.com/api/public/health`
- [ ] Vane responds: `curl http://localhost:3100/api/search -X POST -H "Content-Type: application/json" -d '{"query":"test","focusMode":"webSearch","optimizationMode":"speed"}'`
- [ ] Crawl4ai responds: `curl http://localhost:11235/health`
- [ ] Network connectivity: from merch-miner container, `curl http://vane:3000` resolves
