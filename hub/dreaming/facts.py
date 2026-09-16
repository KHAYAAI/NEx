"""The Phase 3 "dreaming" pipeline's fact store: structured facts
extracted from the event log, embedded and kept in Qdrant, tagged with
the source interaction(s) that produced them, decayed (never silently
deleted) when not reinforced.

Extraction is rule-based (a short list of regexes over the user's own
question text), not model-driven. That's the same scope call as
hub/agent/README.md's for tool-call dispatch, for the same reason:
"extract stable facts/preferences, discard noise" (CLAUDE.md Phase 3)
needs a model that can actually judge what's stable and what's noise.
This hub's model has random, untrained weights (hub/models/README.md)
and can't make that judgment — it would either extract nothing
reliably or extract gibberish labeled as "facts about you," which is
worse than not extracting at all. Deterministic rules over the user's
own words are honest and testable in the meantime; swapping them for
model-driven extraction is the direct next step once real weights
exist, same as the agent loop's tool dispatch.
"""
import re
import sqlite3
import time
import uuid
from pathlib import Path

import httpx
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, PointStruct, VectorParams

COLLECTION = "nex-facts"
FACT_NAMESPACE = uuid.UUID("6c1f9e2a-3b7d-4c2e-9a1f-0d5e8b7c4a11")

# (key, value-extracting regex). First match wins per question.
EXTRACTION_RULES = [
    ("name", re.compile(r"\bmy name is ([A-Za-z][\w \-']{0,40})", re.IGNORECASE)),
    ("location", re.compile(r"\bi live in ([A-Za-z][\w \-,']{0,60})", re.IGNORECASE)),
    ("occupation", re.compile(r"\bi (?:work as|am) an? ([A-Za-z][\w \-]{0,60})", re.IGNORECASE)),
    ("likes", re.compile(r"\bi (?:like|love|enjoy) ([A-Za-z][\w \-]{0,60})", re.IGNORECASE)),
]

AUDIT_SCHEMA = """
CREATE TABLE IF NOT EXISTS dreaming_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms INTEGER NOT NULL,
    action TEXT NOT NULL,       -- 'extract' | 'reinforce' | 'prune'
    fact_key TEXT,
    fact_value TEXT,
    source_event_id INTEGER,
    reason TEXT
);
CREATE TABLE IF NOT EXISTS dreaming_checkpoint (
    id INTEGER PRIMARY KEY CHECK (id = 0),
    last_event_id INTEGER NOT NULL
);
"""


def extract_facts(question: str):
    """Returns a list of (key, value) pairs found in one question."""
    found = []
    for key, pattern in EXTRACTION_RULES:
        m = pattern.search(question)
        if m:
            found.append((key, m.group(1).strip().rstrip(".!?,")))
    return found


def embed(llama_url: str, text: str) -> list[float]:
    resp = httpx.post(f"{llama_url}/embedding", json={"content": text}, timeout=30.0)
    resp.raise_for_status()
    data = resp.json()[0]["embedding"]
    # llama-server's /embedding returns one vector per input token when
    # pooling isn't mean/cls; the server is started with --pooling mean
    # (see hub/scripts/dreaming-demo.sh) so this is normally already a
    # single vector, but be defensive rather than assume.
    return data[0] if isinstance(data[0], list) else data


class FactStore:
    def __init__(self, qdrant_path: Path, audit_db_path: Path, llama_url: str, vector_size: int):
        self.client = QdrantClient(path=str(qdrant_path))
        self.llama_url = llama_url
        self.vector_size = vector_size
        if not self.client.collection_exists(COLLECTION):
            self.client.create_collection(
                COLLECTION, vectors_config=VectorParams(size=vector_size, distance=Distance.COSINE)
            )
        self.audit = sqlite3.connect(audit_db_path)
        self.audit.executescript(AUDIT_SCHEMA)
        self.audit.commit()

    def _log(self, action, fact_key=None, fact_value=None, source_event_id=None, reason=None, now_ms=None):
        self.audit.execute(
            "INSERT INTO dreaming_log (ts_ms, action, fact_key, fact_value, source_event_id, reason) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (now_ms if now_ms is not None else int(time.time() * 1000),
             action, fact_key, fact_value, source_event_id, reason),
        )
        self.audit.commit()

    def get_checkpoint(self) -> int:
        row = self.audit.execute("SELECT last_event_id FROM dreaming_checkpoint WHERE id = 0").fetchone()
        return row[0] if row else 0

    def set_checkpoint(self, last_event_id: int):
        self.audit.execute(
            "INSERT INTO dreaming_checkpoint (id, last_event_id) VALUES (0, ?) "
            "ON CONFLICT(id) DO UPDATE SET last_event_id = excluded.last_event_id",
            (last_event_id,),
        )
        self.audit.commit()

    def _point_id(self, key, value):
        return str(uuid.uuid5(FACT_NAMESPACE, f"{key}:{value.lower()}"))

    def upsert_fact(self, key: str, value: str, source_event_id: int, now_ms=None):
        now_ms = now_ms if now_ms is not None else int(time.time() * 1000)
        point_id = self._point_id(key, value)
        existing = self.client.retrieve(COLLECTION, ids=[point_id])

        if existing:
            payload = existing[0].payload
            payload["reinforcement_count"] += 1
            payload["last_reinforced_ts"] = now_ms
            if source_event_id not in payload["source_event_ids"]:
                payload["source_event_ids"].append(source_event_id)
            payload["status"] = "active"  # a reinforced fact is un-pruned
            self.client.set_payload(COLLECTION, payload=payload, points=[point_id])
            self._log("reinforce", key, value, source_event_id, now_ms=now_ms)
        else:
            vector = embed(self.llama_url, f"{key}: {value}")
            payload = {
                "key": key,
                "value": value,
                "fact_text": f"{key}: {value}",
                "source_event_ids": [source_event_id],
                "first_seen_ts": now_ms,
                "last_reinforced_ts": now_ms,
                "reinforcement_count": 1,
                "status": "active",
                "pruned_at": None,
                "pruned_reason": None,
            }
            self.client.upsert(COLLECTION, points=[PointStruct(id=point_id, vector=vector, payload=payload)])
            self._log("extract", key, value, source_event_id, now_ms=now_ms)

    def prune(self, now_ms: int, max_age_ms: int):
        """Facts not reinforced within max_age_ms of now_ms lose active
        status. Never hard-deleted — the point and its history stay,
        and every prune is logged to dreaming_log, per CLAUDE.md's
        auditable-pruning requirement."""
        pruned = []
        offset = None
        while True:
            points, offset = self.client.scroll(COLLECTION, limit=100, offset=offset)
            for p in points:
                if p.payload["status"] != "active":
                    continue
                age = now_ms - p.payload["last_reinforced_ts"]
                if age > max_age_ms:
                    reason = f"not reinforced in {age / 86_400_000:.1f} days (threshold {max_age_ms / 86_400_000:.1f})"
                    payload = p.payload
                    payload["status"] = "pruned"
                    payload["pruned_at"] = now_ms
                    payload["pruned_reason"] = reason
                    self.client.set_payload(COLLECTION, payload=payload, points=[p.id])
                    self._log("prune", payload["key"], payload["value"], reason=reason, now_ms=now_ms)
                    pruned.append(payload)
            if offset is None:
                break
        return pruned

    def active_facts(self):
        facts = []
        offset = None
        while True:
            points, offset = self.client.scroll(COLLECTION, limit=100, offset=offset)
            facts.extend(p.payload for p in points if p.payload["status"] == "active")
            if offset is None:
                break
        facts.sort(key=lambda f: (-f["reinforcement_count"], -f["last_reinforced_ts"]))
        return facts

    def summarize(self) -> str:
        facts = self.active_facts()
        if not facts:
            return "I don't know anything about you yet."
        lines = ["Here's what I know about you so far:"]
        for f in facts:
            sources = ", ".join(f"#{i}" for i in f["source_event_ids"])
            times = "once" if f["reinforcement_count"] == 1 else f"{f['reinforcement_count']} times"
            lines.append(f"- {f['fact_text']} (mentioned {times}; source interaction(s): {sources})")
        return "\n".join(lines)

    def close(self):
        self.audit.close()
