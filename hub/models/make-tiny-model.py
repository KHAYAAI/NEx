#!/usr/bin/env python3
"""Builds a tiny, real qwen2-architecture GGUF model for the Phase 2 hub
stack demo (see hub/README.md).

This environment's network policy blocks downloads from huggingface.co
(and other model-weight hosts), so a genuine trained Qwen checkpoint
cannot be pulled here. What this script produces instead:

  - a REAL tokenizer: the actual Qwen2 vocabulary and BPE merges, lifted
    from llama.cpp's own test fixture at models/ggml-vocab-qwen2.gguf
    (that file ships in the llama.cpp repo on GitHub, which this
    environment CAN reach — it's there for llama.cpp's tokenizer unit
    tests, not for generation, but the vocab in it is the real thing).
  - a REAL qwen2-architecture graph as llama.cpp defines it (same tensor
    names, same shapes, same attention/FFN wiring — see
    src/models/qwen2.cpp in the llama.cpp source).
  - RANDOM, untrained weights for every tensor, deterministically seeded.

The result loads and runs through the real llama.cpp inference engine
end to end — tokenize, forward pass, attention, sampling, detokenize —
and answers a question over the OpenAI-compatible /completion API. The
words it produces are gibberish, because the weights are random, not
because anything in the pipeline is fake. Swap this file for a real
Qwen3 GGUF (`hub/models/README.md` has the pointer) the moment real
hardware with unrestricted network access is available, and nothing
else in hub/ needs to change — same architecture, same tokenizer, same
server, same agent loop.
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np
from gguf import GGUFReader, GGUFWriter, GGUFValueType

ARCH = "qwen2"


def load_qwen2_vocab(vocab_gguf_path):
    r = GGUFReader(vocab_gguf_path)
    fields = {f.name: f for f in r.fields.values()}

    def scalar_int(name):
        f = fields[name]
        return int(f.parts[f.data[0]][0])

    def scalar_str(name):
        f = fields[name]
        return bytes(f.parts[f.data[0]]).decode("utf-8")

    def array_of_strings(name):
        f = fields[name]
        return [bytes(f.parts[d]).decode("utf-8", errors="replace") for d in f.data]

    def array_of_ints(name):
        f = fields[name]
        return [int(f.parts[d][0]) for d in f.data]

    return {
        "model": scalar_str("tokenizer.ggml.model"),
        "pre": scalar_str("tokenizer.ggml.pre"),
        "tokens": array_of_strings("tokenizer.ggml.tokens"),
        "token_type": array_of_ints("tokenizer.ggml.token_type"),
        "merges": array_of_strings("tokenizer.ggml.merges"),
        "bos_token_id": scalar_int("tokenizer.ggml.bos_token_id"),
        "eos_token_id": scalar_int("tokenizer.ggml.eos_token_id"),
        "padding_token_id": scalar_int("tokenizer.ggml.padding_token_id"),
    }


def build(out_path: Path, vocab_gguf_path: Path, n_embd: int, n_layer: int, n_head: int, seed: int):
    vocab = load_qwen2_vocab(vocab_gguf_path)
    n_vocab = len(vocab["tokens"])
    n_ff = n_embd * 4
    rng = np.random.default_rng(seed)

    def rand(*shape):
        # Small init scale — this is a demo of the pipeline, not a claim
        # that random weights are a sensible starting point for anything.
        return (rng.standard_normal(shape).astype(np.float32) * 0.02)

    writer = GGUFWriter(str(out_path), ARCH)

    writer.add_name("nex-tiny-qwen2-synthetic")
    writer.add_description(
        "Synthetic random-weight qwen2-arch model with the real Qwen2 "
        "tokenizer, for Phase 2 hub-stack pipeline validation. NOT a "
        "trained model — see hub/models/README.md."
    )
    writer.add_context_length(512)
    writer.add_embedding_length(n_embd)
    writer.add_block_count(n_layer)
    writer.add_feed_forward_length(n_ff)
    writer.add_head_count(n_head)
    writer.add_head_count_kv(n_head)
    writer.add_layer_norm_rms_eps(1e-6)
    writer.add_rope_freq_base(1000000.0)
    writer.add_file_type(1)  # GGML_FTYPE_ALL_F16-ish marker; weights below are f32

    writer.add_tokenizer_model(vocab["model"])
    writer.add_tokenizer_pre(vocab["pre"])
    writer.add_token_list(vocab["tokens"])
    writer.add_token_types(vocab["token_type"])
    writer.add_token_merges(vocab["merges"])
    writer.add_bos_token_id(vocab["bos_token_id"])
    writer.add_eos_token_id(vocab["eos_token_id"])
    writer.add_pad_token_id(vocab["padding_token_id"])

    writer.add_tensor("token_embd.weight", rand(n_vocab, n_embd))
    writer.add_tensor("output_norm.weight", np.ones(n_embd, dtype=np.float32))
    writer.add_tensor("output.weight", rand(n_vocab, n_embd))

    for i in range(n_layer):
        writer.add_tensor(f"blk.{i}.attn_norm.weight", np.ones(n_embd, dtype=np.float32))
        writer.add_tensor(f"blk.{i}.attn_q.weight", rand(n_embd, n_embd))
        writer.add_tensor(f"blk.{i}.attn_k.weight", rand(n_embd, n_embd))
        writer.add_tensor(f"blk.{i}.attn_v.weight", rand(n_embd, n_embd))
        writer.add_tensor(f"blk.{i}.attn_output.weight", rand(n_embd, n_embd))
        writer.add_tensor(f"blk.{i}.ffn_norm.weight", np.ones(n_embd, dtype=np.float32))
        writer.add_tensor(f"blk.{i}.ffn_gate.weight", rand(n_ff, n_embd))
        writer.add_tensor(f"blk.{i}.ffn_down.weight", rand(n_embd, n_ff))
        writer.add_tensor(f"blk.{i}.ffn_up.weight", rand(n_ff, n_embd))

    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    writer.write_tensors_to_file()
    writer.close()

    # Sidecar: ids of every CONTROL (3) / USER_DEFINED (4) vocab entry —
    # Qwen2's real special tokens (<|im_start|>, <tool_call>, etc).
    # Random untrained weights sample these by pure chance like any other
    # token, but llama-server's chat-format-aware output parser treats
    # their appearance as structural (expecting a matching close tag,
    # valid tool-call JSON, etc.) and returns HTTP 500 when that
    # expectation isn't met — a real failure this hit repeatedly during
    # testing. hub/agent/agent.py loads this file and suppresses these
    # ids via logit_bias so the model can't sample them, which a real
    # trained model wouldn't need (it uses them correctly) but this
    # untrained one has no way to.
    special_ids = [i for i, t in enumerate(vocab["token_type"]) if t in (3, 4)]
    sidecar_path = out_path.with_suffix(out_path.suffix + ".special_token_ids.json")
    sidecar_path.write_text(json.dumps(special_ids))

    print(f"wrote {out_path} ({out_path.stat().st_size / 1e6:.1f} MB), "
          f"vocab={n_vocab} n_embd={n_embd} n_layer={n_layer} n_head={n_head}")
    print(f"wrote {sidecar_path} ({len(special_ids)} special token ids to suppress)")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--vocab-gguf", type=Path, required=True,
                    help="path to llama.cpp's models/ggml-vocab-qwen2.gguf")
    p.add_argument("--n-embd", type=int, default=64)
    p.add_argument("--n-layer", type=int, default=2)
    p.add_argument("--n-head", type=int, default=2)
    p.add_argument("--seed", type=int, default=42)
    args = p.parse_args()

    if not args.vocab_gguf.exists():
        print(f"missing vocab source file: {args.vocab_gguf}", file=sys.stderr)
        print("clone llama.cpp and point --vocab-gguf at its models/ggml-vocab-qwen2.gguf", file=sys.stderr)
        sys.exit(1)

    build(args.out, args.vocab_gguf, args.n_embd, args.n_layer, args.n_head, args.seed)
