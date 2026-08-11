# Architecture

This document describes the architecture of the MongoDB Vector Search Agent (the `simple-rag-movies` sample).

## Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Azure AI Foundry                                │
│         (ONE AIServices account: agent + embedding + chat models)       │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                    Prompt Agent (gpt-5-mini)                    │   │
│   │                                                                 │   │
│   │   "Find movies about hope"      "Top movies from 2007"          │   │
│   │                    │                    │                       │   │
│   │                    └──────────┬─────────┘                       │   │
│   │                               ▼                                 │   │
│   │                    ┌────────────────────┐                       │   │
│   │                    │   ONE MCP server   │                       │   │
│   │                    │     "MongoDB"      │                       │   │
│   │                    │   (16 tools)       │                       │   │
│   │                    └─────────┬──────────┘                       │   │
│   └──────────────────────────────┼──────────────────────────────────┘   │
│                                  │ MCP over HTTP                        │
└──────────────────────────────────┼──────────────────────────────────────┘
                                   ▼
        ┌────────────────────────────────────────────────────┐
        │             Azure Function  /api/mcp                │
        │             (Flex Consumption, Python)              │
        │                                                     │
        │   semantic_search  → embed + build the              │
        │                      $vectorSearch pipeline         │
        │   all other tools  → relayed to the MCP server      │
        └─────────┬────────────────────────────────┬──────────┘
                  │                                │
                  │ embed                          │ MCP: find / aggregate /
                  ▼                                ▼        count / ...
        ┌──────────────────┐   ┌──────────────────────────────────┐
        │ Foundry account  │   │     Azure Container Apps         │
        │ (same as above)  │   │     MongoDB MCP server  /mcp     │
        │ text-embedding-  │   │                                  │
        │ ada-002          │   │  runs EVERY query, and is the    │
        │ (1536 dims)      │   │  only holder of the connection   │
        │                  │   │  string                          │
        └──────────────────┘   └────────────────┬─────────────────┘
                                                ▼
                        ┌───────────────────────────────────────┐
                        │            MongoDB Atlas              │
                        │  sample_mflix DB                      │
                        │  • movies                             │
                        │  • embedded_movies (with vector_index)│
                        └───────────────────────────────────────┘
```

Three things are worth calling out in that picture.

**The agent registers one MCP server, and that server advertises sixteen tools.** The Function owns exactly one of them, `semantic_search`. On `tools/list` it asks the MongoDB MCP server for its catalogue and re-advertises those fifteen tools as its own; on `tools/call` it forwards anything that is not `semantic_search` straight through and passes the reply back. The Function does not parse filters or pipelines and has no idea what `find` means. The Foundry portal lists MCP *servers* rather than tools, which is why a single entry appears there.

**The MongoDB MCP server runs every query.** Semantic or not, all database work happens in that container. The Function opens no MongoDB connection, has no driver in `requirements.txt`, and is never given the connection string, so it could not reach Atlas even if it tried. This also drives the deployment order: the MCP server is created **before** the Function, because the Function needs its URL.

**The embedding model and the chat model live in the same Azure AI Foundry (AIServices) account**, so there is one endpoint, one key, and one thing to tear down. The Function reaches back into that account's `text-embedding-ada-002` deployment to embed queries.
## Why a hand-written MCP endpoint?

The `gpt-5` family of models **cannot call OpenAPI tools** in a Foundry prompt agent (only code interpreter, file search, and MCP are supported). Vector search therefore has to be exposed as an **MCP tool**, not an OpenAPI action.

The Function implements the MCP protocol directly - **JSON-RPC 2.0 over HTTP POST** at `/api/mcp` - instead of relying on the Azure Functions MCP binding extension. It handles `initialize`, `tools/list`, and `tools/call`, advertising `semantic_search` of its own plus the MongoDB MCP server's tools relayed. This keeps the sample portable across hosting plans and avoids the binding extension entirely.

## Components

### 1. Azure AI Foundry Agent
- **Model**: gpt-5-mini (hosted on the same AIServices account as the embedding model)
- **Role**: Orchestrates tool calls based on user queries
- **Tools**: one MCP server (the Function), which advertises `semantic_search` plus every MongoDB tool
- **Decision Logic**: chooses between `semantic_search` for thematic questions and `find`/`aggregate`/`count` for exact filters

### 2. Embedding + Relay Function (Azure Functions)
- **Runtime**: Python 3.11 on Flex Consumption (remote build - no local Python or Core Tools needed)
- **MCP endpoint**: `/api/mcp` - hand-written JSON-RPC 2.0 server
- **HTTP endpoints**: `/api/embed`, `/api/vector-search`, `/api/health` for smoke tests
- **`semantic_search`**: embeds the query with `text-embedding-ada-002`, builds a `$vectorSearch` pipeline, and asks the MongoDB MCP server to run it
- **Every other tool**: `tools/list` re-advertises the MongoDB MCP server's catalogue; `tools/call` forwards the request verbatim and returns the reply. The Function does not interpret filters or pipelines.
- **Database access**: none. No MongoDB driver, no connection string, no `pymongo` in `requirements.txt` (its only dependency is `azure-functions`).
- **Talks to**: the Foundry account's embedding deployment + the MongoDB MCP server

### 3. MongoDB MCP Server (Azure Container Apps)
- **Image**: `mongodb/mongodb-mcp-server:latest`
- **Protocol**: HTTP-based MCP (Model Context Protocol)
- **Operations**: every database operation in the sample - `find`, `aggregate`, `count`, `collection-schema` and the rest, including the `$vectorSearch` behind `semantic_search`
- **Holds** `MDB_MCP_CONNECTION_STRING`. This is the only component with database credentials.
- **Config**: `MDB_MCP_DISABLED_TOOLS=export` (see [Making the agent answer with data](#making-the-agent-answer-with-data))

### 4. MongoDB Atlas
- **Database**: sample_mflix (MongoDB sample dataset)
- **Collection**: embedded_movies (has the `plot_embedding` field)
- **Index**: vector_index (cosine similarity, 1536 dimensions)
- **Setup**: automated by [`scripts/atlas/setup.ps1`](../scripts/atlas/setup.ps1) (cluster, sample data, database user, network access, vector index) and checked by [`scripts/atlas/verify.py`](../scripts/atlas/verify.py), which connects, queries, and runs a real `$vectorSearch`

## Data Flow

### Semantic Search Query

The agent makes **one** MCP tool call. The Function fans that out into an embedding call and a second MCP call, so the raw vector never touches the model.

```
User: "Find movies about hope"
       │
       ▼
   ┌───────────────┐
   │ Agent decides │─── "This is conceptual → semantic_search"
   │  query type   │
   └───────┬───────┘
           │ MCP tools/call: semantic_search("hope")
           ▼
   ┌────────────────────────────────────────────────┐
   │            Azure Function  /api/mcp             │
   │                                                │
   │  1. embed "hope" via text-embedding-ada-002    │
   │  2. build the $vectorSearch pipeline           │
   │     + $addFields score + allow-list $project   │
   └───────┬────────────────────────────────────────┘
           │ MCP tools/call: aggregate(pipeline)
           ▼
   ┌───────────────┐
   │ MongoDB MCP   │─── $vectorSearch on vector_index
   │ (Container    │        │
   │  Apps)        │        ▼
   └───────┬───────┘   MongoDB Atlas
           │ matched movies + scores (no vectors)
           ▼
   ┌───────────────┐
   │    Agent      │─── formats and presents results
   │   Response    │
   └───────────────┘
```

### Direct Query

For exact filters the agent calls `find`, `aggregate` or `count`. Those tools belong to the MongoDB MCP
server; the Function relays them without interpreting them.

```
User: "Movies from 1994"
       │
       ▼
   ┌───────────────┐
   │ Agent decides │─── "This is a filter → find"
   │  query type   │
   └───────┬───────┘
           │ MCP tools/call: find({ year: 1994 })
           ▼
   ┌────────────────────────────┐
   │ Azure Function  /api/mcp   │─── not semantic_search, so forward it
   └───────┬────────────────────┘
           │ same call, unchanged
           ▼
   ┌───────────────┐
   │ MongoDB MCP   │
   │ (Container    │
   │  Apps)        │
   └───────┬───────┘
           ▼
   ┌───────────────┐
   │ MongoDB Atlas │─── returns matching movies
   └───────┬───────┘
           ▼
   ┌───────────────┐
   │    Agent      │
   │   Response    │
   └───────────────┘
```
## Vector Index Configuration

```json
{
  "fields": [
    {
      "type": "vector",
      "path": "plot_embedding",
      "numDimensions": 1536,
      "similarity": "cosine"
    }
  ]
}
```

## Keeping embeddings out of the response

Every document in `embedded_movies` carries at least one 1536-dimension float array. Returned verbatim, three
results came back as ~39,000 characters of numbers, which wastes the context window and tells the model nothing.

The pipeline's final `$project` is an **allow-list** (`title`, `year`, `plot`, `genres`, `cast`, `score`, and so on)
rather than a deny-list that excludes the known embedding fields. This matters: the sample originally excluded
`plot_embedding_voyage_3_large` by name, MongoDB later renamed that field to `..._voyage_4_large`, and the
exclusion silently stopped matching. An allow-list cannot fail that way. Any new field, embedding or otherwise,
is excluded by default. The same three results are now ~5,000 characters.

## Making the agent answer with data

Two behaviours had to be corrected before the agent gave usable answers, and both are worth knowing if you build
something similar.

**The `export` tool.** The MongoDB MCP server ships an `export` tool, and the agent would happily use it, replying
with an `exported-data://<id>.json` link that nobody can open. It is turned off with
`MDB_MCP_DISABLED_TOOLS=export`, and [`docs/agent-instructions.md`](agent-instructions.md) also tells the agent to
write results into its reply as text.

**Results arrive in two pieces.** The MongoDB MCP server answers a query with two content blocks: a short
summary ("...resulted in 305 documents. Returning 3.") and a second block holding the documents inside an
`<untrusted-user-data-...>` prompt-injection fence. Foundry's MCP client forwards only the first block, so an
agent pointed straight at that server is told how many rows matched and never shown one of them.

This is why the agent talks to the Function rather than to the container. The Function joins the blocks and
returns a single one, and the documents reach the model. The guard itself is correct and stays in place; the
agent simply receives it whole.

## Cost Considerations

| Component | Pricing Model | Typical Cost |
|-----------|---------------|--------------|
| Azure Function | Flex Consumption (pay-per-use, scales to zero) | ~$0/month for low usage |
| Container App (MongoDB MCP) | Consumption (pay-per-vCPU-second) | ~$0-5/month |
| Azure AI Foundry account | Pay-as-you-go (embeddings + gpt-5-mini) | ~$0.0001/embedding + agent inference |
| MongoDB Atlas | M0 (free) to M10+ | $0 - $57+/month |

## Scaling Considerations

- **Azure Function**: Flex Consumption auto-scales (including to zero); no configuration needed
- **MongoDB MCP Server**: set minReplicas/maxReplicas on the Container App for predictable scaling
- **MongoDB Atlas**: choose an appropriate tier (M0 free for the sample; M10+ for production query volume)
