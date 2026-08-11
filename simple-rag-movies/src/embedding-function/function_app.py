"""Azure Function: query embedding + semantic search for the RAG agent.

This function does NOT talk to MongoDB. It has no database driver and no connection string.
Its only jobs are:
  1. Turn query text into a vector using Azure OpenAI.
  2. Hand that vector to the MongoDB MCP server, which is the single component that touches
     the database, and return whatever it finds.

It is exposed as a small MCP server (JSON-RPC 2.0) at /api/mcp, because Foundry agents on
MCP-only models (the gpt-5 family) cannot call OpenAPI or plain HTTP tools. The extra HTTP
routes (/api/embed, /api/vector-search, /api/health) exist for smoke tests.

Doing the embed and the search in one tool call is deliberate: the 1536-dim vector is created
and consumed here, so the agent LLM never has to carry it between two tools.
"""
import azure.functions as func
import json
import logging
import os
import urllib.error
import urllib.request

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

# Azure OpenAI configuration
AZURE_OPENAI_ENDPOINT = os.environ.get("AZURE_OPENAI_ENDPOINT")
AZURE_OPENAI_API_KEY = os.environ.get("AZURE_OPENAI_API_KEY")
EMBEDDING_MODEL = os.environ.get("EMBEDDING_MODEL", "text-embedding-ada-002")

# MongoDB MCP server (Container Apps). This function holds the MCP URL, never a database
# credential: the MCP server owns the connection string and is the only thing that queries Mongo.
MCP_SERVER_URL = os.environ.get("MCP_SERVER_URL")
MCP_PROTOCOL_VERSION = "2024-11-05"
_mcp_session_id = None

# Fields returned for each match. This is an ALLOW-list on purpose. Excluding known embedding
# fields instead looks tidier but is unsafe: sample_mflix renamed its Voyage field from
# plot_embedding_voyage_3_large to ..._4_large, the exclusion silently stopped matching, and a
# 2048-dim vector went straight into the agent's context. An allow-list cannot leak a field the
# dataset adds later. Callers can override it with "fields" on /api/vector-search.
DEFAULT_FIELDS = [
    "title", "year", "plot", "fullplot", "genres", "cast", "directors",
    "runtime", "rated", "languages", "countries", "imdb", "awards", "poster",
]


def _mcp_post(payload: dict, session_id: str | None = None) -> tuple[str | None, str]:
    """POST one JSON-RPC message to the MongoDB MCP server. Returns (session id, raw body)."""
    if not MCP_SERVER_URL:
        raise RuntimeError("MCP_SERVER_URL is not configured")
    headers = {
        "Content-Type": "application/json",
        # The MCP server may answer with either plain JSON or an SSE frame; accept both.
        "Accept": "application/json, text/event-stream",
    }
    if session_id:
        headers["mcp-session-id"] = session_id
    req = urllib.request.Request(MCP_SERVER_URL, data=json.dumps(payload).encode("utf-8"), headers=headers)
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.headers.get("mcp-session-id"), resp.read().decode("utf-8")


def _mcp_parse(raw: str) -> dict:
    """Read a JSON-RPC message that may be wrapped in Server-Sent Events framing."""
    text = raw.strip()
    if text.startswith("{"):
        return json.loads(text)
    for line in text.splitlines():
        if line.startswith("data:"):
            return json.loads(line[5:].strip())
    raise RuntimeError(f"Unrecognized MCP response: {text[:200]}")


def _mcp_connect() -> str:
    """Open (and cache) an MCP session. Sessions are reused across warm invocations."""
    global _mcp_session_id
    if _mcp_session_id:
        return _mcp_session_id
    session_id, _ = _mcp_post({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": MCP_PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "embedding-function", "version": "1.0.0"},
        },
    })
    if not session_id:
        raise RuntimeError("MCP server did not return a session id")
    # The spec requires this acknowledgement before regular requests.
    _mcp_post({"jsonrpc": "2.0", "method": "notifications/initialized"}, session_id)
    _mcp_session_id = session_id
    return session_id


def _mcp_text(result: dict) -> str:
    """Join the text blocks of an MCP tool result."""
    blocks = result.get("content") or []
    return "\n".join(b.get("text", "") for b in blocks if b.get("type") == "text").strip()


def _mcp_call_tool(name: str, arguments: dict) -> dict:
    """Call a tool on the MongoDB MCP server, re-establishing the session once if it expired."""
    global _mcp_session_id
    payload = {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
               "params": {"name": name, "arguments": arguments}}
    try:
        _, raw = _mcp_post(payload, _mcp_connect())
    except urllib.error.HTTPError as e:
        if e.code not in (400, 404):
            raise
        _mcp_session_id = None  # stale session, open a new one and retry once
        _, raw = _mcp_post(payload, _mcp_connect())
    message = _mcp_parse(raw)
    if message.get("error"):
        raise RuntimeError(f"MCP error from {name}: {message['error']}")
    result = message.get("result") or {}
    # A failed tool reports isError in the RESULT rather than as a JSON-RPC error, so this has to
    # be checked explicitly. Without it an error message would be handed back as if it were data.
    if result.get("isError"):
        raise RuntimeError(f"MCP tool '{name}' failed: {_mcp_text(result) or 'unknown error'}")
    return result


def _mcp_list_tools() -> list[dict]:
    """List the tools the MongoDB MCP server offers, so they can be re-advertised from here."""
    global _mcp_session_id
    payload = {"jsonrpc": "2.0", "id": 3, "method": "tools/list"}
    try:
        _, raw = _mcp_post(payload, _mcp_connect())
    except urllib.error.HTTPError as e:
        if e.code not in (400, 404):
            raise
        _mcp_session_id = None
        _, raw = _mcp_post(payload, _mcp_connect())
    message = _mcp_parse(raw)
    if message.get("error"):
        raise RuntimeError(f"MCP error from tools/list: {message['error']}")
    return (message.get("result") or {}).get("tools") or []


def call_azure_openai_embedding(text: str) -> list[float]:
    """Generate embedding vector for text using Azure OpenAI."""
    url = f"{AZURE_OPENAI_ENDPOINT}/openai/deployments/{EMBEDDING_MODEL}/embeddings?api-version=2024-06-01"
    data = json.dumps({"input": text}).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "api-key": AZURE_OPENAI_API_KEY,
            "Content-Type": "application/json"
        }
    )
    with urllib.request.urlopen(req) as response:
        result = json.loads(response.read().decode())
        return result["data"][0]["embedding"]


def _run_vector_search(query: str, database: str = "sample_mflix",
                       collection: str = "embedded_movies", index: str = "vector_index",
                       path: str = "plot_embedding", limit: int = 5,
                       num_candidates: int | None = None,
                       fields: list[str] | None = None) -> dict:
    """Embed the query, then ask the MongoDB MCP server to run the $vectorSearch.

    This function never connects to MongoDB. It builds the pipeline, hands it to the MCP
    server's `aggregate` tool, and returns the documents that come back. The $project stage
    names the fields to KEEP, so no embedding vector can reach the agent.
    """
    if num_candidates is None:
        num_candidates = max(100, limit * 20)
    projection = {"_id": 0, "score": 1}
    for f in (fields or DEFAULT_FIELDS):
        projection[f] = 1
    query_vector = call_azure_openai_embedding(query)
    pipeline = [
        {
            "$vectorSearch": {
                "index": index,
                "path": path,
                "queryVector": query_vector,
                "numCandidates": num_candidates,
                "limit": limit,
            }
        },
        {"$addFields": {"score": {"$meta": "vectorSearchScore"}}},
        {"$project": projection},
    ]
    result = _mcp_call_tool("aggregate", {
        "database": database,
        "collection": collection,
        "pipeline": pipeline,
    })
    text = _mcp_text(result)
    logging.info(f"Vector search '{query[:50]}...' returned {len(text)} chars from the MCP server")
    return {"query": query, "limit": limit, "results": text}


@app.route(route="embed", methods=["POST"])
def generate_embedding(req: func.HttpRequest) -> func.HttpResponse:
    """
    Generate embedding vector for text.
    
    Request body: {"text": "your text here"}
    Response: {"embedding": [0.1, 0.2, ...], "dimensions": 1536, "model": "..."}
    """
    logging.info("Embedding request received")
    
    try:
        body = req.get_json()
    except ValueError:
        return func.HttpResponse(
            json.dumps({"error": "Invalid JSON in request body"}),
            status_code=400,
            mimetype="application/json"
        )
    
    text = body.get("text")
    if not text:
        return func.HttpResponse(
            json.dumps({"error": "Missing required field: text"}),
            status_code=400,
            mimetype="application/json"
        )
    
    try:
        embedding = call_azure_openai_embedding(text)
        logging.info(f"Generated embedding for: {text[:50]}... (dims: {len(embedding)})")
        
        return func.HttpResponse(
            json.dumps({
                "embedding": embedding,
                "dimensions": len(embedding),
                "model": EMBEDDING_MODEL
            }),
            mimetype="application/json"
        )
    except Exception as e:
        logging.error(f"Embedding generation failed: {e}")
        return func.HttpResponse(
            json.dumps({"error": f"Embedding generation failed: {str(e)}"}),
            status_code=500,
            mimetype="application/json"
        )


@app.route(route="vector-search", methods=["POST"])
def vector_search(req: func.HttpRequest) -> func.HttpResponse:
    """
    Semantic vector search: text in, documents out.

    Embeds the query with Azure OpenAI and runs MongoDB $vectorSearch INSIDE this
    function, so the 1536-dim vector is never returned to the agent/LLM. This is the
    single-tool architecture that avoids the LLM transcribing the embedding.

    Request body:
      {
        "query": "movies about hope and redemption",   # required
        "database": "sample_mflix",                      # optional
        "collection": "embedded_movies",                 # optional
        "index": "vector_index",                         # optional
        "path": "plot_embedding",                        # optional (embedding field)
        "limit": 5,                                       # optional
        "numCandidates": 100                              # optional
      }
    Response: {"count": N, "results": [ {<doc without the embedding field>, "score": 0.83} ]}
    """
    logging.info("Vector search request received")

    try:
        body = req.get_json()
    except ValueError:
        return func.HttpResponse(
            json.dumps({"error": "Invalid JSON in request body"}),
            status_code=400,
            mimetype="application/json"
        )

    query = body.get("query") or body.get("text")
    if not query:
        return func.HttpResponse(
            json.dumps({"error": "Missing required field: query"}),
            status_code=400,
            mimetype="application/json"
        )

    try:
        result = _run_vector_search(
            query,
            database=body.get("database", "sample_mflix"),
            collection=body.get("collection", "embedded_movies"),
            index=body.get("index", "vector_index"),
            path=body.get("path", "plot_embedding"),
            limit=int(body.get("limit", 5)),
            num_candidates=int(body["numCandidates"]) if body.get("numCandidates") else None,
            fields=body.get("fields"),
        )
        return func.HttpResponse(
            json.dumps(result, default=str),
            mimetype="application/json"
        )
    except Exception as e:
        logging.error(f"Vector search failed: {e}")
        return func.HttpResponse(
            json.dumps({"error": f"Vector search failed: {str(e)}"}),
            status_code=500,
            mimetype="application/json"
        )


# --- MCP endpoint: JSON-RPC 2.0 over HTTP (Model Context Protocol, Streamable HTTP) ----------
# Implemented by hand as a plain HTTP function (no preview binding extension). Foundry agents on
# MCP-only models (gpt-5 family) point their MCP tool at https://<app>/api/mcp and call the
# `semantic_search` tool. The 1536-dim query vector is created and consumed server-side.
_MCP_PROTOCOL_VERSION = "2024-11-05"
_SEMANTIC_SEARCH_TOOL = {
    "name": "semantic_search",
    "description": ("Semantic vector search over the sample_mflix movie catalog. Pass natural-language "
                    "query text describing a theme, mood, or concept; returns the most relevant movies, "
                    "each with a relevance score. Embedding and $vectorSearch run server-side."),
    "inputSchema": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "Natural-language description of the movies to find."},
            "limit": {"type": "integer", "description": "Maximum number of movies to return (default 5)."},
        },
        "required": ["query"],
    },
}


def _rpc(msg_id, result=None, error=None):
    """Build a JSON-RPC 2.0 HTTP response."""
    body = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        body["error"] = error
    else:
        body["result"] = result
    return func.HttpResponse(json.dumps(body, default=str), mimetype="application/json")


@app.route(route="mcp", methods=["POST", "GET", "DELETE"])
def mcp_endpoint(req: func.HttpRequest) -> func.HttpResponse:
    """Minimal MCP server (JSON-RPC 2.0) exposing the semantic_search tool."""
    if req.method == "GET":
        # Stateless server: no server-initiated SSE stream is offered.
        return func.HttpResponse(status_code=405)
    if req.method == "DELETE":
        return func.HttpResponse(status_code=200)

    try:
        msg = req.get_json()
    except ValueError:
        return _rpc(None, error={"code": -32700, "message": "Parse error"})

    method = msg.get("method")
    msg_id = msg.get("id")

    if method == "initialize":
        return _rpc(msg_id, result={
            "protocolVersion": _MCP_PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "mongo-vector-search", "version": "1.0.0"},
        })
    if method == "ping":
        return _rpc(msg_id, result={})
    if isinstance(method, str) and method.startswith("notifications/"):
        return func.HttpResponse(status_code=202)
    if method == "tools/list":
        # Re-advertise the MongoDB MCP server's own tools alongside semantic_search.
        #
        # WHY THIS PROXY EXISTS: MongoDB MCP returns a tool result as TWO content blocks - a short
        # trusted summary ("...resulted in 305 documents. Returning 3.") and a second block holding
        # the documents inside an <untrusted-user-data-...> fence. Foundry's MCP client forwards
        # only the first block, so an agent pointed straight at that server is told how many rows
        # matched and never shown one of them. Routing through here fixes it: _mcp_text joins the
        # blocks, and the agent receives a single block containing the data.
        tools = [_SEMANTIC_SEARCH_TOOL]
        try:
            tools.extend(_mcp_list_tools())
        except Exception as e:
            logging.error(f"could not list upstream MongoDB tools: {e}")
        return _rpc(msg_id, result={"tools": tools})
    if method == "tools/call":
        params = msg.get("params") or {}
        tool_name = params.get("name")
        args = params.get("arguments") or {}

        if tool_name != "semantic_search":
            # Anything else belongs to the MongoDB MCP server: forward it and flatten the reply.
            try:
                result = _mcp_call_tool(tool_name, args)
                return _rpc(msg_id, result={"content": [{"type": "text", "text": _mcp_text(result)}]})
            except Exception as e:
                logging.error(f"{tool_name} failed: {e}")
                return _rpc(msg_id, result={"isError": True,
                                            "content": [{"type": "text", "text": f"{tool_name} failed: {e}"}]})

        query = args.get("query")
        if not query:
            return _rpc(msg_id, result={"isError": True, "content": [{"type": "text", "text": "query is required"}]})
        try:
            limit = int(args.get("limit") or 5)
        except (ValueError, TypeError):
            limit = 5
        try:
            data = _run_vector_search(query, limit=limit)
            return _rpc(msg_id, result={"content": [{"type": "text", "text": json.dumps(data, default=str)}]})
        except Exception as e:
            logging.error(f"semantic_search failed: {e}")
            return _rpc(msg_id, result={"isError": True, "content": [{"type": "text", "text": f"Semantic search failed: {e}"}]})

    return _rpc(msg_id, error={"code": -32601, "message": f"Method not found: {method}"})


@app.route(route="health", methods=["GET"])
def health_check(req: func.HttpRequest) -> func.HttpResponse:
    """Health check endpoint."""
    return func.HttpResponse(
        json.dumps({
            "status": "healthy",
            "model": EMBEDDING_MODEL,
            "endpoint_configured": bool(AZURE_OPENAI_ENDPOINT),
            "mcp_server_configured": bool(MCP_SERVER_URL)
        }),
        mimetype="application/json"
    )
