---
description: MuAPI - multimodal AI API for image, video, audio, VFX, workflows, and agents
mode: subagent
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

# MuAPI

<!-- AI-CONTEXT-START -->

## Quick Reference

- **API**: `https://api.muapi.ai/api/v1` — auth via `x-api-key: $MUAPI_API_KEY` header
- **Pattern**: POST → `request_id` → poll `/predictions/{id}/result` (`processing` → `completed` | `failed`)
- **Webhooks**: Append `?webhook=https://your.endpoint` to any generation endpoint
- **CLI**: `muapi-helper.sh [flux|video-effects|vfx|motion|music|lipsync|face-swap|upscale|bg-remove|dress-change|stylize|product-shot|storyboard|agent-*|balance|usage|status|help]`
- **Docs**: [muapi.ai/docs](https://muapi.ai/docs/introduction) | [Playground](https://muapi.ai/playground)

<!-- AI-CONTEXT-END -->

## Setup

1. Sign up at [muapi.ai/signup](https://muapi.ai/signup), generate key at [muapi.ai/access-keys](https://muapi.ai/access-keys)
2. Store: `aidevops secret set MUAPI_API_KEY`
3. Test: `muapi-helper.sh flux "A test image" --sync`

## API Pattern

```bash
# Submit
curl -X POST "https://api.muapi.ai/api/v1/{endpoint}" \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${MUAPI_API_KEY}" \
  -d '{"prompt": "...", ...}'

# Poll
curl -X GET "https://api.muapi.ai/api/v1/predictions/${request_id}/result" \
  -H "x-api-key: ${MUAPI_API_KEY}"
```

## Endpoints

### Image Generation (Flux Dev)

```text
POST /api/v1/flux-dev-image
```

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `prompt` | string | Yes | - | Text prompt |
| `image` | string | No | - | Reference image URL (img2img) |
| `mask_image` | string | No | - | Inpainting mask (white=generate, black=preserve) |
| `strength` | number | No | 0.8 | Transform strength (0.0-1.0) |
| `size` | string | No | 1024*1024 | Output size (512-1536 per dimension) |
| `num_inference_steps` | integer | No | 28 | Steps (1-50) |
| `seed` | integer | No | -1 | Reproducibility seed (-1=random) |
| `guidance_scale` | number | No | 3.5 | CFG scale (1.0-20.0) |
| `num_images` | integer | No | 1 | Count (1-4) |

### AI Video Effects, VFX & Motion

Single endpoint, different effect names:

```text
POST /api/v1/generate_wan_ai_effects
```

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `prompt` | string | Yes | - | Effect description |
| `image_url` | string | Yes | - | Source image URL |
| `name` | string | Yes | - | Effect name (case-sensitive, from Playground) |
| `aspect_ratio` | string | No | 16:9 | 1:1, 9:16, 16:9 |
| `resolution` | string | No | 480p | 480p, 720p |
| `quality` | string | No | medium | medium, high |
| `duration` | number | No | 5 | 5-10 seconds |

**Effects:** AI (Cakeify, Film Noir, VHS Footage, Samurai, etc.) · VFX (Building Explosion, Car Explosion, Disintegration, Levitation, Lightning, Tornado, Fire, Ice) · Motion (360 Orbit, Zoom In/Out, Spin, Shake, Bounce, Pan Left/Right)

### Music (Suno)

```text
POST /api/v1/suno-create-music     # New tracks
POST /api/v1/suno-remix-music      # Remix existing
POST /api/v1/suno-extend-music     # Extend existing
```

### Lip-Sync

```text
POST /api/v1/sync-lipsync          # High-fidelity
POST /api/v1/latentsync-video      # Fast
POST /api/v1/creatify-lipsync      # Creatify
POST /api/v1/veed-lipsync          # Veed
```

### Audio (MMAudio)

```text
POST /api/v1/mmaudio-v2/text-to-audio    # Text to audio/Foley/SFX
POST /api/v1/mmaudio-v2/video-to-video   # Sync audio with video
```

### Workflows

```text
POST /api/workflow/{workflow_id}/run
```

Multi-node execution graphs (text, image, video, audio, utility nodes). Build via web UI or Agentic Workflow Architect (natural language).

### Agents

```text
POST   /agents/quick-create              # Create from goal
POST   /agents/suggest                   # Get config suggestion
GET    /agents/skills                    # List skills
POST   /agents                           # Create with skills
GET    /agents/user/agents               # List user's agents
GET    /agents/{agent_id}                # Get details
PUT    /agents/{agent_id}                # Update
DELETE /agents/{agent_id}                # Delete
POST   /agents/{agent_id}/chat           # Chat (use conversation_id for memory)
```

### Specialized Apps

All async, all require `image_url`.

```text
# Portrait & Identity
POST /api/v1/ai-image-face-swap         # Face swap (images) — requires face_image
POST /api/v1/ai-video-face-swap         # Face swap (videos) — requires face_image
POST /api/v1/ai-skin-enhancer           # Skin retouching

# Creative Transformations
POST /api/v1/ai-dress-change            # Outfit swap (optional prompt)
POST /api/v1/ai-ghibli-style            # Studio Ghibli stylization
POST /api/v1/ai-anime-generator         # Anime transformation

# Image Processing
POST /api/v1/ai-image-upscale           # Resolution increase with detail regen
POST /api/v1/ai-background-remover      # Subject isolation
POST /api/v1/ai-object-eraser           # Inpainting removal (optional mask_url)
POST /api/v1/ai-image-extension         # Outpaint (optional prompt)

# Product & Marketing
POST /api/v1/ai-product-shot            # Studio-quality backgrounds (optional prompt)
POST /api/v1/ai-product-photography     # High-converting assets (optional prompt)
```

### Storyboarding

```text
POST /api/storyboard/projects
```

Cinematic production with character persistence across scenes/episodes. Flow: Character (`StoryboardCharacter` with static/dynamic features) → Project (characters + brief) → Episodes → Scenes/Shots (linked to characters/backgrounds). Uses Flux/Runway for generation; assets feed into workflows for post-processing.

### Payments & Credits

```text
POST /api/v1/payments/create_credits_checkout_session   # Purchase (Stripe)
GET  /api/v1/payments/credits                           # Balance
GET  /api/v1/payments/usage                             # History
```

Credit-based (`CreditWallet`): deducted by model cost and duration. Usage log includes cost/status/IO. Enterprise: custom limits, private deployment billing, multi-key tracking.

## CLI Helper

```bash
muapi-helper.sh flux "A cyberpunk city at night"
muapi-helper.sh flux "A portrait" --size 1024*1536 --steps 40
muapi-helper.sh video-effects "a cute kitten" --image URL --effect "Cakeify"
muapi-helper.sh vfx "a car" --image URL --effect "Car Explosion"
muapi-helper.sh motion "a person" --image URL --effect "360 Orbit"
muapi-helper.sh music "upbeat electronic track with synths"
muapi-helper.sh lipsync --video URL --audio URL
muapi-helper.sh face-swap --image URL --face URL    # or --video URL --face URL --mode video
muapi-helper.sh upscale --image URL
muapi-helper.sh bg-remove --image URL
muapi-helper.sh dress-change --image URL "red evening gown"
muapi-helper.sh stylize --image URL --style ghibli
muapi-helper.sh product-shot --image URL "minimalist white studio"
muapi-helper.sh object-erase --image URL --mask URL
muapi-helper.sh image-extend --image URL "extend the landscape"
muapi-helper.sh skin-enhance --image URL
muapi-helper.sh agent-create "I want an agent that creates brand assets"
muapi-helper.sh agent-chat <agent-id> "Design a logo for Vapor"
muapi-helper.sh agent-list
muapi-helper.sh balance
muapi-helper.sh usage
muapi-helper.sh status <request-id>
```

## Models

| Category | Models | Notes |
|----------|--------|-------|
| Image | Flux Dev/Schnell/Pro/Max, Midjourney v7, HiDream | Flux: professional; MJ: aesthetic; HiDream: fast/stylized |
| Video | Wan 2.1/2.2, Runway Gen-3/Act-Two, Kling v2.1, Luma Dream Machine | Wan: speech-to-video/LoRA; Runway: cinematic; Kling: realism; Luma: reframing |
| Audio | Suno, MMAudio-v2, Sync-Lipsync/LatentSync | Music create/remix/extend, text-to-audio, video-to-audio sync, lip-sync |

## Provider Selection

Use `content/media-generation-providers.md` for the canonical gateway and
direct-provider comparison. Choose MuAPI when VFX, specialized apps,
storyboarding, workflows, agents, music, or lipsync orchestration matters;
do not select it solely because an upstream model name overlaps another
gateway.

## Troubleshooting

- **401 Unauthorized**: Verify key set (`echo "${MUAPI_API_KEY:+set}"`), check key copied correctly, verify account has credits
- **Task stuck processing**: Video/effects take 1-2 min. Use `--timeout 600` for long tasks
- **Effect not found**: Names are case-sensitive — use exact name from Playground (e.g., "Cakeify", "Film Noir", "Car Explosion", "360 Orbit")

## Related

- [MuAPI Documentation](https://muapi.ai/docs/introduction) | [Playground](https://muapi.ai/playground)
- `content/media-generation-providers.md` — Canonical provider routing
- `content/video-kie.md` — Kie.ai generic Market task API
- `content/video-wavespeed.md` — WaveSpeed AI (alternative unified API)
- `content/video-runway.md` — Runway API (alternative media pipeline)
- `tools/video/video-prompt-design.md` — Prompt engineering for video models
- `tools/vision/image-generation.md` — Image generation workflows
- `content/production-video.md` — Video production pipeline
- `content/production-audio.md` — Audio production pipeline
