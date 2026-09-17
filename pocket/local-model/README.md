# pocket/local-model

The phone's offline fallback model (`CLAUDE.md` Phase 4). Real,
end-to-end tested: `offline_answer.py` calls a real `llama-server`
running entirely inside a network namespace with no WAN route
(`pocket/scripts/pocket-demo.sh`'s airplane-mode phase), and gets a
real answer back — no network dependency of any kind.

## Why llama.cpp instead of MLC LLM

`DEPENDENCIES.md` names MLC LLM as the phone-optimized target. It
isn't used here: a real MLC LLM deployment needs to compile a real
trained model through TVM for the target device, and a real trained
model needs weights this environment's network policy blocks
downloading — the same wall `hub/models/README.md` hits for the hub's
model. Rather than stub the offline path out, it reuses exactly what
Phase 2 already proved works end-to-end: llama.cpp + the real Qwen2
tokenizer + a small synthetic-weight GGUF (real architecture, random
weights, fluent-looking gibberish output — see `hub/models/README.md`).
Benchmarking MLC LLM/NCNN/MNN against this once real weights and a
real phone are available is tracked as follow-up, not skipped
silently.

## Why this is a thin copy of hub/agent/agent.py's model call, not an import

The pocket node is a separate device with its own codebase in the real
architecture (`CLAUDE.md` §2's two-tier diagram), even though this
session's demo runs both "devices" as processes on one machine. Sharing
code via a Python import across `hub/` and `pocket/` would be a
convenience that doesn't reflect what actually ships.

## Running it

```sh
python3 offline_answer.py "your question" --llama-url http://127.0.0.1:8090 --model-path /path/to/model.gguf
```
