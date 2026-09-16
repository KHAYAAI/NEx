#!/usr/bin/env python3
"""The hub's event log: every interaction gets one row, forever (pruning
is a "dreaming" pipeline concern per CLAUDE.md Phase 3, not this
module's job — it's write-mostly and dumb on purpose).

SQLite is the P2 "raw event-log substrate" per DEPENDENCIES.md — plain
files, no server process, trivially inspectable with the `sqlite3` CLI
or any DB browser, which matters for the project's "auditable down to
the schematic" principle: a user should be able to open this file
themselves and see exactly what their hub has logged about them.
"""
import json
import sqlite3
import time
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS interactions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_ms INTEGER NOT NULL,
    question TEXT NOT NULL,
    answer TEXT NOT NULL,
    tool_used TEXT,
    tool_result TEXT,
    latency_ms REAL NOT NULL,
    model TEXT NOT NULL
);
"""


class EventLog:
    def __init__(self, db_path: Path):
        self.db_path = Path(db_path)
        self.conn = sqlite3.connect(self.db_path)
        self.conn.execute(SCHEMA)
        self.conn.commit()

    def log_interaction(self, *, question, answer, model, latency_ms, tool_used=None, tool_result=None, ts_ms=None):
        # ts_ms override exists for the Phase 3 dreaming-pipeline demo,
        # which simulates "a week of varied test interactions"
        # (CLAUDE.md's Phase 3 exit criteria) without waiting a real
        # week — see hub/scripts/dreaming-demo.sh. Real callers never
        # need it; the default is always the real clock.
        cur = self.conn.execute(
            "INSERT INTO interactions (ts_ms, question, answer, tool_used, tool_result, latency_ms, model) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (ts_ms if ts_ms is not None else int(time.time() * 1000),
             question, answer, tool_used, tool_result, latency_ms, model),
        )
        self.conn.commit()
        return cur.lastrowid

    def since(self, after_id):
        cur = self.conn.execute(
            "SELECT id, ts_ms, question, answer, tool_used, tool_result, latency_ms, model "
            "FROM interactions WHERE id > ? ORDER BY id ASC",
            (after_id,),
        )
        cols = [d[0] for d in cur.description]
        return [dict(zip(cols, row)) for row in cur.fetchall()]

    def recent(self, n=10):
        cur = self.conn.execute(
            "SELECT id, ts_ms, question, answer, tool_used, tool_result, latency_ms, model "
            "FROM interactions ORDER BY id DESC LIMIT ?",
            (n,),
        )
        cols = [d[0] for d in cur.description]
        return [dict(zip(cols, row)) for row in cur.fetchall()]

    def get(self, row_id):
        cur = self.conn.execute(
            "SELECT id, ts_ms, question, answer, tool_used, tool_result, latency_ms, model "
            "FROM interactions WHERE id = ?",
            (row_id,),
        )
        row = cur.fetchone()
        if row is None:
            return None
        cols = [d[0] for d in cur.description]
        return dict(zip(cols, row))

    def close(self):
        self.conn.close()


if __name__ == "__main__":
    import argparse

    p = argparse.ArgumentParser(description="Inspect the hub event log.")
    p.add_argument("db_path", type=Path)
    p.add_argument("-n", type=int, default=10)
    args = p.parse_args()
    log = EventLog(args.db_path)
    print(json.dumps(log.recent(args.n), indent=2))
