# file-search

The first NEx "App": a minimal, low-stakes MCP server exposing one
tool, `search_files`, that greps a directory tree for a literal
substring and returns matching file paths with a snippet of context.

Real MCP protocol (JSON-RPC over stdio, via the official `mcp` Python
SDK) — `hub/agent/agent.py` is a genuine MCP client, not a function
pretending to be one.

Deliberately read-only and confined to a root directory passed on the
command line — no writes, no arbitrary paths, no shell execution. A
hub's tool ecosystem eventually touches real user data and real IoT
devices; the first App is scoped as narrowly as it can be while still
being useful, on purpose.

## Running standalone

```sh
python3 server.py --root /some/directory
```

Speaks MCP over stdio — it's meant to be launched by an MCP client
(`hub/agent/agent.py` does this automatically), not used interactively.
