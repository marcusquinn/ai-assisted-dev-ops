---
description: Local AI model inference via llama.cpp - hardware-aware setup, HuggingFace GGUF models, usage tracking, disk cleanup
mode: subagent
model: simple
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Local Models - llama.cpp Inference

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Runtime**: llama.cpp (MIT, fastest, no daemon, localhost only)
- **Models**: Any GGUF from HuggingFace (Qwen, Llama, DeepSeek, Mistral, Gemma, Phi)
- **API**: OpenAI-compatible at `http://localhost:8080/v1`
- **Helper**: `local-model-helper.sh [setup|start|stop|status|models|download|search|recommend|cleanup|usage|inventory|nudge|benchmark]`

**Use local when**: privacy/compliance, offline, bulk processing, simple tasks. **Avoid for**: complex reasoning, >32K context, frontier-model tasks. See `tools/context/model-routing.md`.

<!-- AI-CONTEXT-END -->

## Why llama.cpp

| Criterion | llama.cpp | Ollama | LM Studio |
|-----------|-----------|--------|-----------|
| Speed | Fastest (baseline) | 20-70% slower | Same engine |
| Security | No daemon, localhost only | 175k+ exposed instances, multiple CVEs | Desktop-safe |
| Binary size | 23-130 MB | ~200 MB | ~500 MB+ |
| Control | Full (quantization, context, sampling) | Abstracted | GUI-mediated |

## Alternative: Ollama

Ollama is a popular alternative that wraps llama.cpp with a daemon and model registry. Use it when you need a simpler setup or ecosystem compatibility (e.g., Open WebUI, Continue.dev).

```bash
# Install
brew install ollama          # macOS
curl -fsSL https://ollama.com/install.sh | sh   # Linux

# Run a model
ollama run gemma3:27b
ollama run llama3.2:3b

# API (OpenAI-compatible)
ollama serve   # starts daemon on http://localhost:11434
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3.2","messages":[{"role":"user","content":"Hello"}]}'
```

**Security caveats:**

- Ollama binds to `0.0.0.0` by default on Linux — exposes port 11434 to the network. Set `OLLAMA_HOST=127.0.0.1` to restrict to localhost.
- 175,000+ Ollama instances are publicly exposed on the internet (Shodan, 2024). Most are misconfigured defaults.
- Multiple CVEs in Ollama history (path traversal, SSRF, model poisoning via crafted Modelfiles). Keep updated.
- The daemon runs persistently and auto-starts on login — increases attack surface vs. llama.cpp's on-demand model.

**`num_ctx` warning:** Ollama defaults to `num_ctx=2048` regardless of model capability. For models with 32K–256K context windows, this silently truncates input. Always set explicitly:

```bash
ollama run gemma3:27b --num-ctx 32768
# or in Modelfile:
PARAMETER num_ctx 32768
```

Failure to set `num_ctx` is the most common cause of poor Ollama performance on long-context tasks.

## Platform Support

| Platform | GPU Acceleration | Binary |
|----------|-----------------|--------|
| macOS ARM64 | Metal (native) | ~29 MB |
| macOS x86_64 | Metal | ~82 MB |
| Linux x64 CPU | None | ~23 MB |
| Linux x64 Vulkan | NVIDIA/AMD/Intel | ~40 MB |
| Linux ROCm | AMD (ROCm runtime required) | ~130 MB |

**NVIDIA/CUDA**: Use Vulkan binary — comparable inference performance. CUDA-specific features: compile from source with `-DGGML_CUDA=ON`.

**Linux ARM64**: No prebuilt binary — compile from source:

```bash
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp && cmake -B build && cmake --build build --config Release -j$(nproc)
cp build/bin/llama-server ~/.aidevops/local-models/bin/
```

## Installation

```bash
local-model-helper.sh setup   # detects platform, downloads binary + shared libraries, installs `hf`, initialises SQLite DB
```

Directory layout: `~/.aidevops/local-models/{bin/,hf-cli-env/,models/,config.json}` · DB: `~/.aidevops/.agent-workspace/memory/local-models.db`

## Hardware & Model Selection

```bash
local-model-helper.sh recommend   # detects RAM/GPU, suggests models with size and tok/s estimates
```

**VRAM/RAM guidelines** (reserve 4 GB for OS; Apple Silicon uses unified memory via Metal):

| Available | Max Model | Recommended Quant |
|-----------|-----------|-------------------|
| 8 GB | ~4 GB | Q4_K_M |
| 16 GB | ~10 GB | Q4_K_M or Q5_K_M |
| 32 GB | ~20 GB | Q5_K_M or Q6_K |
| 64 GB | ~45 GB | Q6_K or Q8_0 |
| 96+ GB | ~70 GB | Q8_0 or FP16 |

**Quantization** (Q4_K_M default — best size/quality balance):

| Quant | Size vs FP16 | Quality Loss |
|-------|-------------|-------------|
| Q4_K_M | ~25% | Minimal |
| Q5_K_M | ~33% | Very small |
| Q6_K | ~50% | Negligible |
| Q8_0 | ~66% | None measurable |
| IQ4_XS | ~22% | Small — absolute minimum size |

**Models by use case** (prefer family over specific versions — models release frequently):

| Use Case | Family | Size |
|----------|--------|------|
| Code | Qwen3, DeepSeek-Coder | 4-8B |
| General chat | Llama 3, Qwen3, Gemma 3 | 4-8B |
| Reasoning | DeepSeek-R1, Qwen3 thinking | 7-14B |
| Summarization | Llama 3, Phi-4 | 4-8B |
| Translation | Qwen3, NLLB | 4-8B |
| Embeddings (RAG) | nomic-embed, bge-large | 0.1-0.3B |

## Recommended Local Models (2026)

Current top picks by hardware tier. Benchmarks as of Q1 2026.

### Gemma 4 27B MoE — Best overall (16 GB+ RAM)

Google's Gemma 4 27B uses a Mixture-of-Experts architecture with only 3.8B parameters active per forward pass, giving frontier-class quality at a fraction of the compute cost.

| Metric | Value |
|--------|-------|
| LiveCodeBench | 77.1% |
| Active params | 3.8B (of 27B total) |
| Context window | 256K tokens |
| VRAM (Q4_K_M) | ~14 GB |
| Recommended quant | Q4_K_M or Q5_K_M |

```bash
local-model-helper.sh download google/gemma-4-27b-it-GGUF --quant Q4_K_M
local-model-helper.sh start --model gemma-4-27b-it-q4_k_m.gguf --ctx-size 32768
```

Best for: code generation, reasoning, long-context tasks. The MoE architecture means inference speed is closer to a 4B model than a 27B model.

### Gemma 4 4B (E4B) — Best for laptops (8 GB RAM)

The E4B ("Efficient 4B") variant is optimised for edge devices. Outperforms most 7B models from 2024 on coding and instruction following.

```bash
local-model-helper.sh download google/gemma-4-4b-it-GGUF --quant Q4_K_M
local-model-helper.sh start --model gemma-4-4b-it-q4_k_m.gguf --ctx-size 16384
```

Best for: MacBook Air (8 GB), low-power Linux servers, always-on assistants.

### Gemma 4 31B Dense — Max quality (32 GB+ RAM)

The dense 31B variant (non-MoE) delivers the highest single-query quality in the Gemma 4 family. Slower than the MoE but better for tasks requiring deep reasoning across the full parameter space.

```bash
local-model-helper.sh download google/gemma-4-31b-it-GGUF --quant Q5_K_M
local-model-helper.sh start --model gemma-4-31b-it-q5_k_m.gguf --ctx-size 32768 --gpu-layers 99
```

Best for: M2/M3 Max (64 GB+), workstations, batch processing where quality > speed.

### Quick selection guide

| Hardware | Recommended model | Quant |
|----------|------------------|-------|
| 8 GB RAM | Gemma 4 4B (E4B) | Q4_K_M |
| 16 GB RAM | Gemma 4 27B MoE | Q4_K_M |
| 32 GB RAM | Gemma 4 27B MoE | Q6_K |
| 64 GB+ RAM | Gemma 4 31B Dense | Q5_K_M or Q8_0 |

## Usage

```bash
# Download
local-model-helper.sh search "qwen3 8b"
local-model-helper.sh download Qwen/Qwen3-8B-GGUF --quant Q4_K_M

# Start/stop
local-model-helper.sh start --model qwen3-8b-q4_k_m.gguf [--port 8080] [--ctx-size 8192] [--threads 8] [--gpu-layers auto]
local-model-helper.sh stop
local-model-helper.sh status   # PID, model, API URL, uptime, requests

# API (OpenAI-compatible)
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"Explain quicksort"}],"max_tokens":256}'

curl http://localhost:8080/v1/embeddings -H "Content-Type: application/json" \
  -d '{"model":"local","input":"The quick brown fox"}'

curl http://localhost:8080/health
```

Server defaults (`~/.aidevops/local-models/config.json`): port 8080, host 127.0.0.1, ctx_size 8192, threads auto (perf cores), gpu_layers auto, flash_attn true.

## aidevops Integration

```bash
model-availability-helper.sh check local          # exit 0 if server running
compare-models-helper.sh compare local sonnet haiku
response-scoring-helper.sh prompt "Explain X" --models local,haiku,sonnet
```

> Helper scripts must recognise `local` tier (tracked in t1338).

## Usage Tracking & Cleanup

```bash
local-model-helper.sh usage [--since YYYY-MM-01] [--json]   # requests, tokens, tok/s, estimated cloud cost saved
local-model-helper.sh nudge      # session-start check: warns if stale models >5 GB (unused >30d)
local-model-helper.sh cleanup    # shows disk usage + stale status
local-model-helper.sh cleanup --remove-stale          # remove models unused >30d
local-model-helper.sh cleanup --remove <model.gguf>   # remove specific model
local-model-helper.sh cleanup --threshold 60          # change stale threshold (days)
local-model-helper.sh benchmark --model <file>        # tok/s, time-to-first-token
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `setup` fails on Linux | Check glibc (`ldd --version`); ROCm: ensure runtime installed; try `setup --update` |
| Slow inference | Verify `gpu_layers` set; check Metal/CUDA detected via `status` |
| Download interrupted | Re-run `download` — `hf` resumes automatically |
| Out of memory | Use Q4_K_M or smaller model; check `recommend` |
| Port in use | `start --port 8081` or `stop` existing |
| Context crash | Reduce `--ctx-size`; larger contexts need more RAM |
| Binary outdated | `setup --update` |

## Security

Binds to `127.0.0.1` only. No daemon, no telemetry, no external connections during inference. No API keys required.

## See Also

- `tools/local-models/huggingface.md` — GGUF format, quantization, trusted publishers
- `tools/context/model-routing.md` — cost-aware routing (local = free tier)
- `tools/infrastructure/cloud-gpu.md` — cloud GPU for larger models
- `tools/ai-assistants/compare-models.md` — model comparison including local
- `tools/voice/speech-to-speech.md` — voice pipeline with local LLM step
