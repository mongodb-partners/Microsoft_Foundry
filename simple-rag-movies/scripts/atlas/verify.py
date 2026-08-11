"""Verify a MongoDB Atlas cluster is ready for the simple-rag-movies sample.

Runs four checks, in order, and exits non-zero on the first failure:
  1. Connect to the cluster.
  2. sample_mflix.embedded_movies exists and has documents.
  3. plot_embedding is present and 1536-dim (text-embedding-ada-002 compatible).
  4. The vector_index actually works: runs a real $vectorSearch and confirms it
     returns results (proves connect + query + index end-to-end).

The connection string is read from MDB_MCP_CONNECTION_STRING (falling back to
MDB_CONNECTION_STRING), so the secret is never passed on the command line or
printed. atlas/setup.ps1 sets that variable for you before calling this script.

Exit codes: 0 = all checks passed, 1 = a check failed, 2 = misconfiguration.
"""
import os
import sys

try:
    from pymongo import MongoClient
    from bson.binary import Binary
except ImportError:
    print("pymongo is not installed. Run:  pip install pymongo dnspython")
    sys.exit(2)

DB = "sample_mflix"
COLL = "embedded_movies"
INDEX = "vector_index"
PATH = "plot_embedding"
EXPECTED_DIMS = 1536

conn = os.environ.get("MDB_MCP_CONNECTION_STRING") or os.environ.get("MDB_CONNECTION_STRING")
if not conn:
    print("ERROR: set MDB_MCP_CONNECTION_STRING (or MDB_CONNECTION_STRING) to your Atlas connection string.")
    sys.exit(2)


def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


# 1. Connect
try:
    client = MongoClient(conn, serverSelectionTimeoutMS=15000)
    client.admin.command("ping")
    print("OK  1/4  Connected to the cluster.")
except Exception as exc:  # noqa: BLE001 - report any connection problem verbatim
    fail(f"could not connect: {exc}")

# 2. Database + collection + documents
if DB not in client.list_database_names():
    fail(f"database '{DB}' not found. Load the sample dataset first.")
db = client[DB]
if COLL not in db.list_collection_names():
    fail(f"collection '{DB}.{COLL}' not found. Load the sample dataset first.")
coll = db[COLL]
count = coll.count_documents({})
if count == 0:
    fail(f"'{DB}.{COLL}' is empty.")
print(f"OK  2/4  {DB}.{COLL} has {count} documents.")

# 3. Embedding present + correct dimensions
doc = coll.find_one({PATH: {"$exists": True}})
if not doc:
    fail(f"no document has a '{PATH}' field.")
emb = doc[PATH]
query_vector = list(emb.as_vector().data) if isinstance(emb, Binary) else list(emb)
dims = len(query_vector)
if dims != EXPECTED_DIMS:
    fail(f"'{PATH}' has {dims} dims, expected {EXPECTED_DIMS} (text-embedding-ada-002 mismatch risk).")
print(f"OK  3/4  '{PATH}' is {dims}-dim (sample title: {doc.get('title')}).")

# 4. Vector search works. Query with an existing document's own embedding: it
#    should come back as a top hit, which proves the index is built and queryable.
try:
    pipeline = [
        {"$vectorSearch": {
            "index": INDEX,
            "path": PATH,
            "queryVector": query_vector,
            "numCandidates": 50,
            "limit": 3,
        }},
        {"$project": {"_id": 0, "title": 1, "score": {"$meta": "vectorSearchScore"}}},
    ]
    hits = list(coll.aggregate(pipeline))
except Exception as exc:  # noqa: BLE001 - surface the Atlas error to the user
    fail(f"$vectorSearch on index '{INDEX}' errored: {exc}. Is the index built and named '{INDEX}'?")

if not hits:
    fail(f"$vectorSearch on '{INDEX}' returned no results. The index may still be building - wait a minute and re-run.")
top = ", ".join(f"{h.get('title')} ({h.get('score', 0):.3f})" for h in hits)
print(f"OK  4/4  {INDEX} is queryable. Top matches: {top}")

print("\nALL CHECKS PASSED - Atlas is ready for the agent.")
client.close()
