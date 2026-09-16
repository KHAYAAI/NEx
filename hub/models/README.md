# hub/models

The model llama-server loads for the Phase 2 hub stack.

## Why this is a synthetic model, not a real Qwen checkpoint

This environment's network policy blocks outbound access to huggingface.co
and other model-weight hosts (verified: `curl` to huggingface.co returns a
`403` from the egress proxy). A real trained Qwen3 checkpoint cannot be
downloaded here. Rather than skip Phase 2's "local model answers a
question" bring-up entirely, `make-tiny-model.py` builds a small,
real-architecture GGUF instead:

- **Real tokenizer.** The actual Qwen2 vocabulary and BPE merges, read
  directly out of `ggml-vocab-qwen2.gguf` — a test fixture that ships
  inside the [llama.cpp repo](https://github.com/ggml-org/llama.cpp) on
  GitHub (reachable from this environment) for llama.cpp's own tokenizer
  unit tests. The vocab in it is the real Qwen2 vocab; it's just not
  packaged with any trained weights, because it's for testing
  tokenization, not generation.
- **Real qwen2-architecture graph.** Same tensor names, same shapes, same
  attention/FFN wiring llama.cpp's own `src/models/qwen2.cpp` expects —
  this loads and runs through the actual inference engine, not a mock.
- **Random, untrained weights.** Deterministically seeded (`--seed`,
  default 42), tiny by design (`--n-embd 64 --n-layer 2 --n-head 2` by
  default — a few tens of MB, not gigabytes).

The result answers questions with fluent-looking multilingual gibberish —
the tokenizer is real so the *shape* of the output looks like real text,
but the weights never learned anything, so the *content* is noise. That's
expected and correct: it proves the pipeline (tokenize → forward pass →
attention → sampling → detokenize → HTTP response), not the model's
knowledge.

## A real bug this surfaced

Random sampling over a real chat-tuned tokenizer's vocabulary can
legitimately land on structural noise that llama-server's chat-format PEG
parser misreads as a broken tool-call or reasoning block, returning
HTTP 500 instead of the plain text. `hub/agent/agent.py` works around
this two ways: suppressing Qwen's actual special/control token ids via
`logit_bias` (this file's `make-tiny-model.py` writes the id list to a
`<model>.gguf.special_token_ids.json` sidecar), and retrying on a 500
since each retry is a fresh, independent sample. Both are documented
in-line in `agent.py` — a real trained model wouldn't need either, since
it uses those tokens correctly instead of stumbling into them at random.

## Regenerating it

```sh
python3 make-tiny-model.py \
  --out /tmp/nex-hub-models/nex-tiny-qwen2.gguf \
  --vocab-gguf /path/to/llama.cpp/models/ggml-vocab-qwen2.gguf \
  --n-embd 64 --n-layer 2 --n-head 2
```

Not committed to the repo — it's regenerated on demand by
`hub/scripts/hub-stack-demo.sh`, deterministically, from a script rather
than a binary blob.

## Swapping in a real model later

The moment real hardware with unrestricted network access is available:
download a real Qwen3 GGUF (or convert one with llama.cpp's
`convert_hf_to_gguf.py`), point `llama-server`/`hub/scripts/hub-stack-demo.sh`'s
`MODEL_PATH` at it, and drop the `--model-path` sidecar argument from
`agent.py`'s invocation (a real model has no special-token sampling
problem to work around). Nothing else in `hub/` needs to change — same
tokenizer, same architecture, same server, same agent.
