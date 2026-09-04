---
description: Provider-neutral routing for AI image, video, audio, avatar, enhancement, and local generation workflows
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Media Generation Provider Routing

<!-- AI-CONTEXT-START -->

## Purpose

Choose the provider before loading its implementation agent. This is the
canonical comparison surface; provider agents document their own interfaces
and must not maintain competing cross-provider tables.

Provider choice is a workload decision, not a model-name lookup. The same
upstream model can differ by version, parameters, moderation, queueing, price,
retention, and support when accessed through a gateway.

## Routing Order

1. **Privacy and locality**: if source media cannot leave the machine, use
   local ComfyUI and local post-production tools.
2. **Required account or contract**: use the user's named direct provider when
   they require its official SDK, support, billing, or provider-only feature.
3. **Specialized outcome**: route avatar/presenter work to HeyGen, portrait
   enhancement to Enhancor, and code-composed editing to Remotion.
4. **Gateway workflow**: choose among Kie.ai, MuAPI, and WaveSpeed based on the
   control surface below, then verify the exact model schema and live price.
5. **Production safety**: check credits before batches, preserve task IDs, use
   callbacks where supported, and download temporary results immediately.

## Provider Matrix

| Route | Prefer when | Primary strengths | Main trade-off |
|-------|-------------|-------------------|----------------|
| **Kie.ai** (`video-kie.md`) | One generic Market task contract should cover changing image, video, and audio models | JSON pass-through, unified status, uploads, credits, callback HMAC | Model inputs remain provider-specific; gateway stability and retention require defensive handling |
| **MuAPI** (`video-muapi.md`) | The workflow needs creative orchestration beyond single generation calls | VFX, specialized apps, storyboards, workflows, agents, music and lipsync | Large provider-specific surface; use only when those orchestration features matter |
| **WaveSpeed** (`video-wavespeed.md`) | Broad multimodal or 3D access and a queryable current model list are important | Image, video, audio, 3D, utilities, model-list endpoint | Inputs and capabilities vary by routed model |
| **Runway** (`video-runway.md`) | A direct Runway media pipeline or official SDK behaviour is required | Video, image, audio, task management, Node.js/Python SDKs | Narrower provider catalog than gateways |
| **Higgsfield API/UI** (`video-higgsfield.md`, `video-higgsfield-ui.md`) | Higgsfield creative tooling, character references, or existing subscription credits drive the task | Multi-model creative workflows; API and browser/subscription routes | API and UI credit pools differ; browser automation is operationally heavier |
| **Gemini web app** (`gemini-image.md`, `gemini-video.md`, `gemini-music.md`) | An authorized Gemini account and its existing plan or allowance should produce a local image, video, or music asset | Persistent per-account Brave profiles, headed login, headless operation, local Downloads delivery | Consumer UI and allowance visibility can change; prefer an official API for unattended production |
| **Direct Sora/Veo** (`production-video.md`) | The production brief already selects Sora or Veo and direct API semantics are required | Focused UGC/cinematic production templates and seed workflows | Not a general provider abstraction |
| **HeyGen** (`heygen-skill.md`) | The deliverable is an avatar, presenter, translation, or talking-head video | Avatar and speech-led video workflows | Specialized rather than general scene generation |
| **ComfyUI** (`tools/ai-generation/comfy-cli.md`) | Local control, privacy, reusable graphs, or custom models dominate | Local execution and explicit workflows | Setup, hardware, model storage, and node maintenance |
| **Enhancor** (`video-enhancor.md`) | Existing portraits need enhancement after generation | Face-aware enhancement and upscale | Post-processing only |
| **Remotion** (`tools/video/remotion.md`) | Assets need deterministic code-based assembly, captions, or animation | Reproducible React compositions and rendering | Composes media; it is not a generation-model gateway |

## Decision Checks

- **Do not translate schemas across providers.** Load the selected provider
  agent and use its exact model ID, authentication, and input fields.
- **Do not select from marketing claims alone.** Confirm current model support,
  price, queue limits, output rights, and retention from first-party sources.
- **Do not test with paid generations by default.** Run mocked transport tests
  for helpers; make a live request only when it resolves material uncertainty
  and the user has authorized the cost.
- **Do not hide asynchronous state.** A submitted task is not a completed asset;
  return task IDs and make timeout recovery explicit.
- **Consume campaign jobs as requirements, not provider selections.** A
  schema-v1 production manifest names asset class, format, rights, disclosure,
  and fallback. Verify current capability evidence before setting its provider
  route; an unavailable capability stays `blocked` rather than silently
  switching providers.
- **Do not preserve stale capability tables.** Update this file when a new
  provider changes routing; keep provider agents focused on their own contract.

## Common Handoffs

| Need | Route |
|------|-------|
| Image generation or editing | `production-image.md` -> this file -> selected provider |
| Generated video shots | `production-video.md` -> this file -> selected provider |
| Voice/music generation | `production-audio.md` -> this file -> selected provider |
| Avatar video | `heygen-skill.md` |
| Post-production assembly | `tools/video/remotion.md` or `tools/video/video-editor.md` |
| Local/private generation | `tools/ai-generation/comfy-cli.md` |

<!-- AI-CONTEXT-END -->
