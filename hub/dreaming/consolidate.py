#!/usr/bin/env python3
"""The Phase 3 "dreaming" pipeline (CLAUDE.md §5, Phase 3): a nightly
job that reads the event log since its last run, extracts stable facts
(see facts.py for why extraction is rule-based, not model-driven right
now), stores them in the fact store, and prunes anything not
reinforced in a while — never silently: every prune is logged.

Explicitly NOT fine-tuning. Nothing here touches model weights, and it
never should in v0 (CLAUDE.md's risk register calls this out
specifically — catastrophic forgetting, no rollback, no safety
framework in place yet).

Intended to run as a nightly systemd timer / cron job in production
(see hub/flake.nix's nex-dreaming timer declaration); this script is
what that timer actually invokes.
"""
import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "memory"))
from eventlog import EventLog  # noqa: E402
from facts import FactStore, extract_facts  # noqa: E402


def run(*, event_db, qdrant_path, audit_db, llama_url, vector_size, now_ms, max_age_ms):
    log = EventLog(event_db)
    store = FactStore(qdrant_path, audit_db, llama_url, vector_size)

    checkpoint = store.get_checkpoint()
    new_events = log.since(checkpoint)

    extracted = 0
    for event in new_events:
        for key, value in extract_facts(event["question"]):
            # Reinforcement time is when the interaction actually
            # happened (event["ts_ms"]), not when this consolidation run
            # happens (now_ms) — those differ in the demo's simulated
            # week, and conflating them made every fact look like it was
            # last mentioned on the day of whichever run first saw it,
            # breaking decay entirely (a real bug this hit during testing).
            store.upsert_fact(key, value, event["id"], now_ms=event["ts_ms"])
            extracted += 1

    if new_events:
        store.set_checkpoint(new_events[-1]["id"])

    pruned = store.prune(now_ms=now_ms, max_age_ms=max_age_ms)

    log.close()
    store.close()
    return {
        "events_processed": len(new_events),
        "facts_touched": extracted,
        "facts_pruned": len(pruned),
        "pruned": pruned,
    }


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--event-db", type=Path, required=True)
    p.add_argument("--qdrant-path", type=Path, required=True)
    p.add_argument("--audit-db", type=Path, required=True)
    p.add_argument("--llama-url", default="http://127.0.0.1:8090")
    p.add_argument("--vector-size", type=int, default=64)
    p.add_argument("--now-ms", type=int, default=None,
                    help="override 'now' for the decay clock — testing only, see hub/scripts/dreaming-demo.sh")
    p.add_argument("--max-age-days", type=float, default=7.0,
                    help="facts not reinforced within this many days lose active status")
    args = p.parse_args()

    now_ms = args.now_ms if args.now_ms is not None else int(time.time() * 1000)
    result = run(
        event_db=args.event_db,
        qdrant_path=args.qdrant_path,
        audit_db=args.audit_db,
        llama_url=args.llama_url,
        vector_size=args.vector_size,
        now_ms=now_ms,
        max_age_ms=int(args.max_age_days * 86_400_000),
    )
    print(f"processed {result['events_processed']} new event(s), "
          f"touched {result['facts_touched']} fact(s), "
          f"pruned {result['facts_pruned']} fact(s)")
    for f in result["pruned"]:
        print(f"  pruned: {f['fact_text']} — {f['pruned_reason']}")


if __name__ == "__main__":
    main()
