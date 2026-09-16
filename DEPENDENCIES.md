# NEx Dependencies

Every open source project (and a few closed-but-essential toolchains) the build relies on, tagged by the earliest phase in `CLAUDE.md` that needs it. Pull a project in when its phase starts — don't front-load Phase 6 dependencies into Phase 1 setup.

Legend: **P0** Scaffolding · **P1** Sync protocol · **P2** Hub bring-up · **P3** Dreaming pipeline · **P4** Pocket node · **P5** Integration · **P6** Hardening · **P7** Multi-hub mesh (stretch)

## Base models

| Project | Origin | Phase | Notes |
|---|---|---|---|
| Qwen3 / Qwen3.5 / Qwen3.6 (0.6B–235B, Apache 2.0) | Alibaba (China) | P2 | Primary model family, hub and pocket tiers both |
| MiniCPM-V / MiniCPM-o (1.3B–4.5B) | OpenBMB/Tsinghua (China) | P4 | Edge-deployment-first, multimodal — leading candidate for pocket node offline fallback |
| GLM-4 / GLM-4.5 (9B class) | Zhipu/THUDM (China) | P2 | Alternate, strong on code/function-calling |
| DeepSeek-R1-Distill | DeepSeek (China) | P2 | Alternate for harder reasoning queries |
| Gemma 3/4, Phi-4-mini, Llama 3.1/3.3 | Google/Microsoft/Meta (US) | P2 | Comparison baseline; relevant later for NEx OS defense customers where non-Chinese origin may matter |

## Agent runtime / orchestration

| Project | Phase | Notes |
|---|---|---|
| smolagents | P2 | Default per D4 — thin, auditable |
| LangGraph | P2 (reserve) | Fallback if the agent loop needs more complex branching later |
| OpenClaw / Hermes Agent | — (reserve) | Only if D4 gets revisited; faster to stand up, less auditable |

## Model gateway

| Project | Phase | Notes |
|---|---|---|
| LiteLLM | — (conditional on D1) | Only needed if any cloud fallback is approved |

## Tool / app connectivity

| Project | Phase | Notes |
|---|---|---|
| MCP servers (open ecosystem) | P2 | Start with one low-stakes server (file search) per Phase 2 exit criteria |

## On-device inference engines

| Project | Origin | Phase | Notes |
|---|---|---|---|
| llama.cpp | Int'l | P2 | Universal baseline |
| Ollama / vLLM | US | P2 | Hub-side serving layer |
| TensorRT-LLM | NVIDIA (US) | P2 | Jetson-tier only, if D3 lands on Jetson |
| RKLLM / RKNN-Toolkit2 | Rockchip (China) | P2 | Required for RK3588/RK3576 tier |
| TPU-MLIR / LLM-TPU | SOPHGO (China) | P2 | Required for Sophon SE9/BM1688 tier — open, Apache 2.0 |
| MLC LLM | US | P4 | Phone-optimized cross-platform baseline |
| NCNN | Tencent (China) | P4 | Lightweight ARM-optimized alternate — benchmark against MLC LLM |
| MNN | Alibaba (China) | P4 | Same niche as NCNN, second option to benchmark |
| PaddleLite | Baidu (China) | P4 (reserve) | Third option, only if NCNN/MNN hit a model-support gap |

## Memory / personalization

| Project | Phase | Notes |
|---|---|---|
| Letta (MemGPT) | P2 | Persistent agent memory |
| Mem0 | P2 (reserve) | Simpler alternate if Letta is heavier than needed |
| LanceDB | P4 | Embeddable, phone-side vector store |
| Qdrant | P2 | Hub-side vector store |
| SQLite + sqlite-vec | P2 | Raw event-log substrate |
| LlamaIndex | P3 | Personal RAG layer for the dreaming pipeline |

## Speech

| Project | Phase | Notes |
|---|---|---|
| whisper.cpp / Faster-Whisper | P4 | Streamed to hub when connected |
| Piper | P2 | Local TTS on hub responses |
| Silero VAD | P4 | Voice activity detection, pocket node |
| openWakeWord | P4 | Local wake-word detection |

## Sync / transport / identity

| Project | Phase | Notes |
|---|---|---|
| WireGuard | P1 | Transport layer under everything |
| Headscale | P1 | Self-hosted control plane |
| Automerge / Yjs | P1 | CRDT sync — the moat, build and test first |
| libp2p | P1 | Peer discovery/transport under the CRDT layer |
| age | P0 | Identity/secrets encryption |
| Matrix (Synapse/Conduit) | P6+ (stretch) | Only if multi-user/multi-device messaging is needed beyond hub↔phone |

## Sandboxing

| Project | Phase | Notes |
|---|---|---|
| gVisor / Firecracker | P6 | Hub-side agent/tool runtime isolation |
| Wasmtime | P6 | Lightweight in-process sandboxing |

## OS / update mechanism

| Project | Phase | Notes |
|---|---|---|
| NixOS | P0 | Hub OS, per D2 default |
| OSTree / RAUC | P0 (conditional on D2) | Only if D2 lands on a non-Nix embedded image |
| LineageOS / /e/OS | P4 | Pocket node base |
| GrapheneOS | — | Study only — source-available, not redistributable, do not fork |
| postmarketOS | — (long-term) | Not a v0 dependency |
| Mender / balenaOS/balenaCloud | P6 | Fleet OTA update mechanism |

## Automation / skills workflow

| Project | Phase | Notes |
|---|---|---|
| n8n / Node-RED | P2+ (v1) | Pre-built visual workflows, complements raw agent tool-calling |

## IoT / home integration

| Project | Phase | Notes |
|---|---|---|
| Home Assistant | P2 | Phase 2 exit criteria requires controlling one real device |
| ESPHome | P2 | Device firmware layer under Home Assistant |
| Zigbee2MQTT | P2 | Zigbee device bridge |

## Secrets management

| Project | Phase | Notes |
|---|---|---|
| SOPS + age | P0 | Encrypts credentials at rest; hardened further in P6 with SE050 |

## App distribution

| Project | Phase | Notes |
|---|---|---|
| F-Droid (own repo) | P6 | Distributing App/MCP-pack updates |
| Obtainium | P6 | Compatible feed alternative |

## Observability

| Project | Phase | Notes |
|---|---|---|
| Prometheus + Grafana | P0 (CI), P6 (hub) | CI test harness from P0; hub-side metrics driving the "dreaming" status light from P6 |

## Mesh (multi-hub, stretch)

| Project | Phase | Notes |
|---|---|---|
| exo | P7 | Compute pooling across multiple hub units — additive to, not a replacement for, the P1 CRDT sync |

## Mobile app framework

| Project | Phase | Notes |
|---|---|---|
| Flutter | P4 | Cross-platform pocket node UI shell |

## Hardware-adjacent (not software, but gates specific phases)

| Item | Phase | Notes |
|---|---|---|
| Infineon/NXP SE050 secure element | P6 | Hardware-anchored device identity |
| Quectel/ST modem module | P4/P6 | Isolated behind the kill switch, documented boundary |
