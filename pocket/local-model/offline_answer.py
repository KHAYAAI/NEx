#!/usr/bin/env python3
"""The pocket node's offline fallback model (CLAUDE.md Phase 4): answers
a question using a local model with no network dependency at all — the
path exercised when the phone is in airplane mode.

DEPENDENCIES.md names MLC LLM as the phone-optimized target for this.
It isn't used here: MLC LLM's toolchain needs to compile a model
through TVM for the target device, which for a *real* 3-8B model needs
real trained weights this environment's network policy blocks
downloading (same constraint documented in hub/models/README.md).
Rather than stub this out, it reuses the pipeline Phase 2 already
proved end-to-end on the hub: llama.cpp + the real Qwen2 tokenizer +
a small synthetic-weight GGUF. Real architecture, fake knowledge — the
same honest tradeoff as everywhere else in this repo that hits the
network-weights wall. Benchmarking MLC LLM/NCNN/MNN against this once
real weights and a real phone are available is tracked, not skipped
silently — see pocket/README.md.

This is intentionally a thin copy of hub/agent/agent.py's model-calling
logic rather than an import from hub/ — the pocket node is a separate
device with its own codebase in the real architecture, even though
this demo runs both "devices" on one machine.
"""
import argparse
import json
import sys
from pathlib import Path

import httpx


def _load_special_token_ids(model_path: Path | None) -> list[int]:
    if model_path is None:
        return []
    sidecar = model_path.with_suffix(model_path.suffix + ".special_token_ids.json")
    if not sidecar.exists():
        return []
    return json.loads(sidecar.read_text())


def offline_answer(llama_url: str, question: str, *, model_path: Path | None = None, max_tokens: int = 64) -> str:
    """See hub/agent/agent.py's call_local_model for why the retry and
    logit_bias suppression exist — same untrained-model/PEG-parser
    interaction, same fix, independently applied here since pocket
    doesn't depend on hub's code."""
    special_ids = _load_special_token_ids(model_path)
    last_error = None
    for _ in range(5):
        resp = httpx.post(
            f"{llama_url}/completion",
            json={
                "prompt": question,
                "n_predict": max_tokens,
                "logit_bias": [[tid, -100.0] for tid in special_ids] if special_ids else [],
            },
            timeout=30.0,
        )
        if resp.status_code == 200:
            return resp.json()["content"]
        last_error = resp
    last_error.raise_for_status()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("question")
    p.add_argument("--llama-url", default="http://127.0.0.1:8090")
    p.add_argument("--model-path", type=Path, default=None)
    args = p.parse_args()
    print(offline_answer(args.llama_url, args.question, model_path=args.model_path))


if __name__ == "__main__":
    main()
