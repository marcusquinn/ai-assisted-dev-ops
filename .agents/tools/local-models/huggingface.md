---
description: HuggingFace model discovery - GGUF format, quantization guidance, hardware-tier recommendations, trusted publishers
mode: subagent
model: simple
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: true
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# HuggingFace Model Discovery

## Quick Reference

- **Purpose**: Find, evaluate, and download GGUF models from HuggingFace for local inference via llama.cpp
- **CLI**: `hf download <repo> <file> --local-dir <path>` (resume-capable; legacy `huggingface-cli` remains supported)
- **Install**: `local-model-helper.sh setup` (isolated environment), or `uv tool install huggingface_hub`. Token: `~/.cache/huggingface/token`
- **Format**: GGUF — single file (weights + tokenizer + metadata), llama.cpp native. Naming: `{model}-{size}-{quant}.gguf`
- **Helper**: `local-model-helper.sh search|download|models|recommend|setup`
- **Browse**: `https://huggingface.co/models?library=gguf&sort=trending`
- **Trusted publishers**: bartowski (first choice), lmstudio-community, ggml-org, unsloth; official authors (Qwen, meta-llama, deepseek-ai, mistralai, google) preferred when available. **Avoid**: few downloads, no README, unclear quant labels.
- **See also**: `tools/local-models/local-models.md` (runtime), `tools/context/model-routing.md` (routing), `tools/infrastructure/cloud-gpu.md` (cloud GPU)

## Quantization

**Default: Q4_K_M** — best size/quality balance. Size estimate: `Parameters (B) × Bits / 8 ≈ GB` (e.g., 8B Q4_K_M ≈ 4.5 GB ±10%).

| Quant | Bits | Size vs FP16 | Use When |
|-------|------|-------------|----------|
| Q4_K_M | 4 | ~25% | **Default** — RAM tight or balanced |
| Q5_K_M | 5 | ~33% | RAM headroom, better quality |
| Q6_K | 6 | ~50% | Near-lossless, important tasks |
| Q8_0 | 8 | ~66% | Maximum quality |
| IQ4_XS | 4 | ~22% | Minimum size, still usable |
| IQ3_XXS | 3 | ~17% | Extreme compression |

## Hardware-Tier Recommendations

Reserve ≥4 GB for OS.

| RAM | Example Hardware | Budget | Recommended (higher-quant) |
|-----|-----------------|--------|---------------------------|
| 8 GB | MacBook Air M2, GTX 1070 | ≤4 GB | Qwen3-4B Q4_K_M (~2.5 GB), Phi-4-mini Q4_K_M (~2.3 GB) |
| 16 GB | MacBook Pro M3, RTX 3060 12GB | ≤10 GB | Qwen3-8B Q4_K_M (~5 GB), Llama-3.1-8B Q4_K_M (~4.7 GB) |
| 32 GB | MacBook Pro M3 Pro, RTX 4090 | ≤20 GB | Qwen3-14B Q4_K_M (~8.5 GB), DeepSeek-R1-Distill-Qwen-14B Q4_K_M (~8.5 GB) (8B Q6_K ~6.5 GB) |
| 64 GB | MacBook Pro M3 Max, dual RTX 4090 | ≤45 GB | Qwen3-32B Q4_K_M (~19 GB), Qwen3-32B Q5_K_M (~24 GB) (14B Q8_0 ~15 GB) |
| 128 GB+ | Mac Studio M2 Ultra, multi-GPU | 70B+ | Qwen3-72B Q4_K_M (~42 GB), Llama-3.1-70B Q4_K_M (~40 GB) (32B Q8_0 ~34 GB) |

## Model Families

| Family | Sizes | Strengths | HuggingFace Repos |
|--------|-------|-----------|-------------------|
| **Qwen3** (Alibaba) | 4B–72B | Best all-round 2026: code, multilingual, reasoning. CoT via system prompt. | `Qwen/Qwen3-{size}-GGUF`, `bartowski/Qwen3-{size}-GGUF` |
| **Llama 3/3.1** (Meta) | 3B–70B | Strong general-purpose. Gated — requires HF token. | `meta-llama/Llama-3.1-{size}-Instruct-GGUF`, `bartowski/...` |
| **DeepSeek R1** | 7B–70B | Built-in chain-of-thought. Strong reasoning and code. | `deepseek-ai/DeepSeek-R1-Distill-Qwen-{size}-GGUF`, `bartowski/...` |
| **Mistral/Mixtral** | 7B–46B | Efficient instruction following. Mixtral-8x7B is MoE (12B active). | `mistralai/Mistral-{size}-Instruct-v0.3-GGUF`, `bartowski/...` |
| **Gemma 3** (Google) | 4B–27B | Instruction following, multilingual, structured output. | `google/gemma-3-{size}-it-GGUF`, `bartowski/...` |
| **Phi 4** (Microsoft) | 3.8B–14B | Capable for size, good reasoning in constrained environments. | `microsoft/phi-4-gguf`, `bartowski/phi-4-GGUF` |

## Download

```bash
# Helper (recommended)
local-model-helper.sh search "qwen3 8b"
local-model-helper.sh search "llama 3.1" --max-size 10G

# Direct download
hf download Qwen/Qwen3-8B-GGUF qwen3-8b-q4_k_m.gguf \
  --local-dir ~/.aidevops/local-models/models/

# Gated models (Llama, etc.) — login first, accept license on HF page
hf auth login
hf download meta-llama/Llama-3.1-8B-Instruct-GGUF \
  llama-3.1-8b-instruct-q4_k_m.gguf --local-dir ~/.aidevops/local-models/models/
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Download interrupted | Re-run same command — resumes automatically |
| "Access denied" | `hf auth login` + accept license on HF page |
| Model too slow | Lower quantization or smaller model |
| Gibberish output | Re-download (corruption), use instruct/chat variant |
| Can't find GGUF | Search `bartowski/{model-name}-GGUF` |
| "Not enough memory" | Smaller model or lower quant; `local-model-helper.sh recommend` |
