---
description: Hosting platform decision guide — Fly.io, Daytona, Coolify, Cloudron, Vercel comparison
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Hosting Platform Decision Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

| Platform | Model | Best for | Pricing model |
|----------|-------|----------|---------------|
| **Fly.io** | Managed PaaS (Firecracker VMs) | Global apps, AI sandboxes, auto-stop/start | Per-second compute + storage |
| **Daytona** | Cloud sandbox (SaaS) | AI agent code execution, GPU, ephemeral CI | Per-second, per-resource |
| **Coolify** | Self-hosted PaaS | Cost control, data sovereignty, Docker apps | Server cost only |
| **Cloudron** | Self-hosted app platform | Off-the-shelf apps, SSO, non-technical teams | Server cost + optional subscription |
| **Vercel** | Serverless/Edge PaaS | Next.js, JAMstack, serverless functions | Invocations + bandwidth |

**Platform docs**: `fly-io.md` | `daytona.md` | `coolify.md` | `cloudron-app-packaging.md` | `vercel.md`

**OS/image selection**: Apply [contextual OS recommendations](../../reference/os-selection.md)
before provisioning. Prefer compatible Hetzner ARM workloads and supported Rocky
Coolify hosts; Cloudron instead requires its documented Ubuntu x64 host. Verify
the exact provider image, architecture, vendor release, and operating burden.

**Scope**: This guide compares application platforms, not conventional WordPress
hosting providers. For WordPress hosting, use `aidevops/recommendations.md`:
Hostinger is the managed starting point, Hetzner is the self-managed option, and
Cloudflare suits edge/static/headless aims; Closte is legacy-only.

<!-- AI-CONTEXT-END -->

Verify pricing before committing: [Fly.io](https://fly.io/docs/about/pricing/) · [Daytona](https://www.daytona.io/pricing) · [Coolify](https://coolify.io/pricing) · [Cloudron](https://www.cloudron.io/pricing.html) · [Vercel](https://vercel.com/pricing) · [Hetzner](https://www.hetzner.com/cloud/)

---

## Feature Comparison

| Dimension | Fly.io | Daytona | Coolify | Cloudron | Vercel |
|-----------|--------|---------|---------|----------|--------|
| **Compute model** | Firecracker micro-VMs | gVisor sandboxes | Docker containers | Docker containers | Serverless functions |
| **Auto-stop/start** | Yes | Yes (manual stop) | No | No | N/A |
| **Cold start** | ~200-500 ms | ~90 ms | None | None | ~0-500 ms |
| **Global distribution** | Yes (30+ regions, anycast) | No | No | No | Yes (100+ PoPs) |
| **Persistent volumes** | NVMe (region-specific) | Snapshots | Docker volumes | /app/data | External only |
| **Managed databases** | Postgres, Upstash Redis | No | PostgreSQL, MySQL, MongoDB, Redis | MySQL, PostgreSQL, Redis | External only |
| **AI agent sandboxes** | Yes (Sprites) | Yes (core use case) | No | No | No |
| **AI isolation** | Firecracker VM (high) | gVisor kernel (very high) | Docker namespace (medium) | Docker namespace (medium) | V8 isolate (JS only) |
| **GPU support** | No | Yes (A100, H100, L40S) | No | No | No |
| **Stateful snapshots** | No | Yes | No | No | No |
| **SDK/API lifecycle** | Machines API | Python/TS SDK | No | No | No |
| **Max execution time** | Unlimited | Unlimited | Unlimited | Unlimited | 5-15 min |
| **Data sovereignty** | No | No | Yes | Yes | No |
| **App marketplace** | No | No | No | Yes (200+ apps) | No |
| **SSO/LDAP** | No | No | No | Yes | No |
| **Automatic SSL** | Yes | N/A | Yes | Yes | Yes |
| **Free tier** | 3 VMs | Credits | Software free | 2 apps | Generous |

---

## Pricing

### Fly.io

| Machine | vCPU | RAM | Always-on/mo |
|---------|------|-----|-------------|
| shared-cpu-1x | 1 shared | 256 MB | ~$1.94 |
| shared-cpu-4x | 4 shared | 1 GB | ~$7.76 |
| performance-1x | 1 dedicated | 2 GB | ~$31 |
| performance-4x | 4 dedicated | 8 GB | ~$124 |

Storage: ~$0.15/GB/mo. Bandwidth: ~$0.02/GB after 160 GB free.

### Daytona

Per-second billing for active vCPU + RAM + disk; stopped sandboxes pay disk only. ~$48-50/mo always-on 1 vCPU/1 GB vs Fly.io ~$6/mo — expensive always-on, competitive for bursty/ephemeral.

### Coolify / Cloudron (self-hosted)

| Provider | Spec | Monthly |
|----------|------|---------|
| Hetzner CX22 | 2 vCPU, 4 GB | ~EUR4.35 |
| Hetzner CX32 | 4 vCPU, 8 GB | ~EUR8.70 |
| DigitalOcean | 2 vCPU, 4 GB | ~$24 |

Coolify: free (AGPL). Cloudron: free for 2 apps; ~$15/mo unlimited.

---

## Decision Guide

| Use case | Recommended | Alternative | Avoid |
|----------|-------------|-------------|-------|
| Global low-latency app | Fly.io | Vercel (frontend) | Coolify, Cloudron |
| Always-on, single region, cost-sensitive | Coolify on Hetzner | Fly.io | Daytona, Vercel |
| AI agent code execution | Fly.io (Sprites) | Daytona (gVisor+GPU) | Coolify, Cloudron, Vercel |
| AI agent with GPU | Daytona | -- | Fly.io, others (no GPU) |
| Ephemeral CI/CD runners | Daytona | Fly.io (auto-stop) | Coolify, Cloudron, Vercel |
| Next.js / JAMstack frontend | Vercel | Fly.io | Coolify, Cloudron |
| Self-hosted app catalogue (WordPress, Nextcloud) | Cloudron | Coolify | Fly.io, Daytona, Vercel |
| Production SaaS, cost-sensitive | Coolify on Hetzner | Fly.io | Daytona |
| Production SaaS, global | Fly.io | Vercel (frontend) + Fly.io (backend) | Coolify |
| Dev environments / previews | Daytona | Vercel (frontend) | Coolify, Cloudron |
| Data sovereignty required | Coolify | Cloudron | Fly.io, Daytona, Vercel |

**Rule of thumb**: Coolify/Cloudron wins on cost and control for single-region always-on. Fly.io/Vercel wins on global distribution, auto-scaling, and zero-ops.

---

## AI Model Inference Hosting

Managed platforms (Fireworks, Together AI, Cloudflare Workers AI, NEAR AI Cloud) expose OpenAI-compatible APIs — change `base_url` only. Raw GPU providers depend on the inference server: vLLM and TGI expose OpenAI-compatible APIs; others may not — verify before integrating.

### Platform Comparison

| Platform | Type | Fine-tuning | Custom uploads | Dedicated GPUs | Docs |
|----------|------|-------------|----------------|----------------|------|
| **Fireworks AI** | Managed inference + training | SFT, DPO, RFT | Yes (HF, S3, Azure) | A100/H100/H200/B200 | `tools/infrastructure/fireworks.md` |
| **Together AI** | Managed inference + training | SFT, DPO, RL | Yes | H100/H200/B200/GB200 | `tools/infrastructure/together.md` |
| **Cloudflare Workers AI** | Edge serverless | No | No | No (serverless) | `tools/infrastructure/cloudflare-ai.md` |
| **NVIDIA Cloud** | Cloud API + self-host (NIM) | NeMo (separate) | Self-host any NIM | Self-host or DGX Cloud | `tools/infrastructure/nvidia-cloud.md` |
| **NEAR AI Cloud** | TEE-backed private inference | No | No | No | `tools/infrastructure/nearai.md` |
| **Cloud GPU** | Raw providers | Any (self-managed) | N/A | RunPod/Vast.ai/Lambda | `tools/infrastructure/cloud-gpu.md` |

### Pricing ($/M tokens, March 2026)

| Model | Fireworks | Together AI | Cloudflare | NEAR AI | Notes |
|-------|-----------|-------------|------------|---------|-------|
| GPT-OSS 120B (in/out) | $0.15 / $0.60 | $0.15 / $0.60 | $0.35 / $0.75 | $0.15 / $0.55 | CF ~2x more |
| DeepSeek V3 (in/out) | $0.56 / $1.68 | $0.60 / $1.70 | N/A | $1.05 / $3.10 | NEAR ~2x (TEE) |
| Llama 3.3 70B (in/out) | $0.90 / $0.90 | $0.88 / $0.88 | $0.29 / $2.25 | N/A | CF cheap in, expensive out |
| Qwen3 30B A3B (in/out) | $0.15 / $0.60 | $0.15 / $1.50 | $0.05 / $0.34 | $0.15 / $0.55 | CF cheapest |
| GLM-5 (in/out) | $1.00 / $3.20 | $1.00 / $3.20 | N/A | $0.85 / $3.30 | Parity |
| Kimi K2.5 (in/out) | $0.60 / $3.00 | $0.50 / $2.80 | $0.60 / $3.00 | N/A | Together slightly cheaper |
| Batch discount | 50% off | 50% off | N/A | N/A | |

NVIDIA Cloud: free endpoints for prototyping (1000 credits). Production via self-hosted NIM containers. No per-token serverless pricing.

### Inference Decision Guide

| Requirement | Recommended | Alternative |
|-------------|-------------|-------------|
| Production inference, lowest cost | Fireworks or Together AI | Cloudflare (small models) |
| Fine-tuning (SFT/DPO/RFT) | Fireworks | Together AI |
| Custom training loops | Fireworks (Training SDK) | Cloud GPU |
| Edge/global, Cloudflare stack | Cloudflare Workers AI | Fireworks (multi-region) |
| Privacy-critical (TEE) | NEAR AI Cloud | Self-hosted NIM in TEE |
| Self-hosted optimized inference | NVIDIA Cloud (NIM) | vLLM/TGI on Cloud GPU |
| Anonymized closed-model access | NEAR AI Cloud | Direct provider APIs |
| Batch processing at scale | Fireworks or Together AI (50% off) | Cloud GPU |
| GPU clusters for training | Together AI | Cloud GPU providers |
| Cheapest experimentation | Cloudflare (10K free neurons/day) | NVIDIA Cloud (free credits) |

---

## Related

- `tools/deployment/fly-io.md` — Fly.io deployment (flyctl, Machines API, Sprites, Tigris)
- `tools/deployment/daytona.md` — Daytona sandbox (gVisor, GPU, ephemeral CI)
- `tools/deployment/coolify.md` — Coolify self-hosted PaaS
- `tools/deployment/vercel.md` — Vercel serverless/edge
- `tools/deployment/uncloud.md` — Uncloud multi-machine container orchestration
- `.agents/scripts/fly-io-helper.sh` — Fly.io CLI helper
