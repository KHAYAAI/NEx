#!/usr/bin/env python3
"""The Phase 2 minimal agent loop from CLAUDE.md: answer a question using
the local model, optionally calling one MCP tool, and log every
interaction to the event log — all within the exit criteria's 1-second
logging budget.

Tool-call decisions here are made by simple rule (a `search:` prefix on
the question), not by the model. That's a scope call, not an oversight:
smolagents (Decision D4) drives tool selection FROM the model's own
output, which requires a model actually capable of deciding when a tool
is useful — this hub currently runs the synthetic random-weight model
described in hub/models/README.md (real trained weights need real
hardware with network access this environment doesn't have). Wiring
smolagents in now would mean threading a real framework through a code
path that can't yet be exercised meaningfully, since random weights
never reliably emit valid tool-call syntax. What's demonstrated here
instead is real: a real MCP client talking the real protocol to a real
tool server, a real local-model call, and a real sub-second log write.
Swapping the rule-based dispatch below for smolagents' model-driven
version is exactly the next step once real weights are in place — the
MCP server, the event log, and the llama.cpp server underneath don't
need to change at all.
"""
import argparse
import asyncio
import json
import sys
import time
from pathlib import Path

import httpx
from mcp import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "memory"))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dreaming"))
from eventlog import EventLog  # noqa: E402
from facts import FactStore  # noqa: E402

APPS_DIR = Path(__file__).resolve().parent.parent / "apps"
RECALL_PHRASE = "what do you know about me"


async def call_mcp_tool(server_script: Path, server_args: list[str], tool_name: str, tool_args: dict) -> str:
    """Generic MCP client call — real protocol, real subprocess, for any
    of hub/apps/'s servers. hub/apps/README.md lists what's available."""
    params = StdioServerParameters(command=sys.executable, args=[str(server_script), *server_args])
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool(tool_name, tool_args)
            return "\n".join(
                block.text for block in result.content if getattr(block, "type", None) == "text"
            )


def _load_special_token_ids(model_path: Path | None) -> list[int]:
    if model_path is None:
        return []
    sidecar = model_path.with_suffix(model_path.suffix + ".special_token_ids.json")
    if not sidecar.exists():
        return []
    return json.loads(sidecar.read_text())


def call_local_model(llama_url: str, prompt: str, *, model_path: Path | None = None, max_tokens: int = 64) -> str:
    # llama.cpp's chat-format-aware output parser (active on both
    # /v1/chat/completions and, in current llama-server, /completion too)
    # runs a PEG grammar over the raw output looking for structural
    # markers (tool calls, reasoning tags). Suppressing Qwen's actual
    # special/control tokens via logit_bias (below) cuts down how often
    # this misfires, but doesn't eliminate it: the grammar's trigger
    # patterns can still be coincidentally, partially matched by ordinary
    # vocab tokens in a long-enough random sequence, and llama-server
    # treats a failed structural parse as HTTP 500 rather than falling
    # back to plain content. This is specific to feeding the parser truly
    # random, untrained output (hub/models/README.md) — a real trained
    # model doesn't emit near-miss structural noise like this — so rather
    # than trying to out-think a PEG grammar we don't control, retry:
    # each retry is a fresh sample, and hitting the same edge case twice
    # in a row is rare in practice (this was verified empirically while
    # building the hub-stack demo — see hub/scripts/hub-stack-demo.sh).
    special_ids = _load_special_token_ids(model_path)
    last_error = None
    for _ in range(5):
        resp = httpx.post(
            f"{llama_url}/completion",
            json={
                "prompt": prompt,
                "n_predict": max_tokens,
                "logit_bias": [[tid, -100.0] for tid in special_ids] if special_ids else [],
            },
            timeout=30.0,
        )
        if resp.status_code == 200:
            return resp.json()["content"]
        last_error = resp
    last_error.raise_for_status()


def recall_answer(question: str, *, qdrant_path: Path | None, audit_db: Path | None, llama_url: str, vector_size: int):
    """Phase 3's exit criterion: "the hub's answers to 'what do you know
    about me' visibly reflect accumulated facts, and every fact is
    traceable back to the source interaction that produced it." This is
    answered directly from the fact store (hub/dreaming/facts.py), not
    the local model — the model's random weights would just add noise
    on top of an already-correct, already-traceable answer."""
    if qdrant_path is None or audit_db is None:
        return None
    store = FactStore(qdrant_path, audit_db, llama_url, vector_size)
    reply = store.summarize()
    store.close()
    return reply


async def answer(question: str, *, llama_url: str, mcp_root: Path, model_path: Path | None,
                  qdrant_path: Path | None = None, audit_db: Path | None = None, vector_size: int = 64,
                  apps_data_dir: Path | None = None):
    tool_used = None
    tool_result = None
    prompt = question

    if question.strip().lower().rstrip("?") == RECALL_PHRASE:
        recalled = recall_answer(
            question, qdrant_path=qdrant_path, audit_db=audit_db, llama_url=llama_url, vector_size=vector_size
        )
        if recalled is not None:
            return recalled, "fact_recall", None

    lowered = question.lower()
    apps_data_dir = apps_data_dir or Path(".")

    if lowered.startswith("search:"):
        query = question.split(":", 1)[1].strip()
        tool_used = "search_files"
        tool_result = await call_mcp_tool(
            APPS_DIR / "file-search" / "server.py", ["--root", str(mcp_root)], "search_files", {"query": query}
        )
        prompt = f"Using this file search result, answer the question.\n\nSearch result for {query!r}:\n{tool_result}\n\nQuestion: {query}"

    elif lowered.startswith("notes:"):
        # "notes: add <text>" or "notes: list"
        rest = question.split(":", 1)[1].strip()
        tool_used = "notes"
        server_args = ["--store", str(apps_data_dir / "notes.json")]
        if rest.lower().startswith("add "):
            tool_result = await call_mcp_tool(
                APPS_DIR / "notes" / "server.py", server_args, "add_note", {"text": rest[4:].strip()}
            )
        else:
            tool_result = await call_mcp_tool(APPS_DIR / "notes" / "server.py", server_args, "list_notes", {})
        prompt = f"Using this notes-app result, answer the question.\n\nResult:\n{tool_result}\n\nQuestion: {question}"

    elif lowered.startswith("home:"):
        # "home: get <device>" or "home: set <device> <state>"
        rest = question.split(":", 1)[1].strip()
        tool_used = "smart_home"
        server_args = ["--store", str(apps_data_dir / "devices.json")]
        parts = rest.split()
        if parts and parts[0].lower() == "set" and len(parts) >= 3:
            tool_result = await call_mcp_tool(
                APPS_DIR / "smart-home" / "server.py", server_args,
                "set_device_state", {"device": parts[1], "state": " ".join(parts[2:])},
            )
        elif parts and parts[0].lower() == "get" and len(parts) >= 2:
            tool_result = await call_mcp_tool(
                APPS_DIR / "smart-home" / "server.py", server_args, "get_device_state", {"device": parts[1]}
            )
        else:
            tool_result = f"couldn't parse home-automation command: {rest!r}"
        prompt = f"Using this smart-home result, answer the question.\n\nResult:\n{tool_result}\n\nQuestion: {question}"

    reply = call_local_model(llama_url, prompt, model_path=model_path)
    return reply, tool_used, tool_result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("question")
    p.add_argument("--llama-url", default="http://127.0.0.1:8090")
    p.add_argument("--db-path", type=Path, required=True)
    p.add_argument("--mcp-root", type=Path, default=Path("."))
    p.add_argument("--model-path", type=Path, default=None,
                    help="path to the GGUF being served — used to find its "
                         "<model>.special_token_ids.json sidecar, if any")
    p.add_argument("--model-label", default="nex-tiny-qwen2-synthetic")
    p.add_argument("--qdrant-path", type=Path, default=None,
                    help="Phase 3 fact store path — enables 'what do you know about me' (see hub/dreaming/)")
    p.add_argument("--facts-audit-db", type=Path, default=None)
    p.add_argument("--vector-size", type=int, default=64)
    p.add_argument("--apps-data-dir", type=Path, default=None,
                    help="where the notes/smart-home apps persist their state (see hub/apps/)")
    args = p.parse_args()

    log = EventLog(args.db_path)
    t0 = time.monotonic()
    reply, tool_used, tool_result = asyncio.run(
        answer(
            args.question, llama_url=args.llama_url, mcp_root=args.mcp_root, model_path=args.model_path,
            qdrant_path=args.qdrant_path, audit_db=args.facts_audit_db, vector_size=args.vector_size,
            apps_data_dir=args.apps_data_dir,
        )
    )
    latency_ms = (time.monotonic() - t0) * 1000

    row_id = log.log_interaction(
        question=args.question,
        answer=reply,
        model=args.model_label,
        latency_ms=latency_ms,
        tool_used=tool_used,
        tool_result=tool_result,
    )

    print(reply)
    print(f"[logged as interaction #{row_id}, {latency_ms:.1f}ms]", file=sys.stderr)
    if tool_used:
        print(f"[used tool: {tool_used}]", file=sys.stderr)
    log.close()


if __name__ == "__main__":
    main()
