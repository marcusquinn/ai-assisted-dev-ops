---
description: "Image generation - text-to-image models for creating visuals from prompts"
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Image Generation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **OpenCode tool**: `gpt_image_generate`
- **Default billing route**: ChatGPT subscription OAuth from the aidevops OpenAI account pool
- **Platform billing route**: explicit `auth: "api"` plus a named account alias
- **Model**: GPT Image 2 (`gpt-image-2`); project-confined PNG, JPEG, or WebP output
- **Reference images**: up to 8 project-relative PNG, JPEG, or WebP files
- **Safety**: existing files are never overwritten; versioned paths use `-v2`, `-v3`, and so on

<!-- AI-CONTEXT-END -->

## Model Comparison

| Model | Provider | Quality | Speed | Cost | Local | Best For |
|-------|----------|---------|-------|------|-------|----------|
| **GPT Image 2** | OpenAI | Very high | Medium | Subscription or API pricing | No | General purpose, text rendering, reference-guided edits |
| **Midjourney v6** | Midjourney | Very high | Medium | $10-60/mo | No | Artistic, photorealistic |
| **Imagen 3** | Google | High | Fast | API pricing | No | Photorealism, Google ecosystem |
| **Ideogram 2.0** | Ideogram | High | Fast | Free tier + paid | No | Text in images, logos |
| **FLUX.1 [dev]** | Black Forest Labs | High | Medium | Free (local) | Yes | Open-source, customisable |
| **FLUX.1 [schnell]** | Black Forest Labs | Good | Fast | Free (local) | Yes | Fast local generation |
| **SD XL** | Stability AI | Good | Fast | Free (local) | Yes | Established ecosystem, ControlNet |
| **SD 3.5** | Stability AI | High | Medium | Free (local) | Yes | Latest Stability model |

```text
Text in images?       → GPT Image 2 or Ideogram
Photorealistic?       → Midjourney or Imagen 3
Full local control?   → FLUX.1 [dev] or SD XL
Fast local iteration? → FLUX.1 [schnell]
ControlNet / img2img? → SD XL (most mature ecosystem)
Simplest OpenCode use? → gpt_image_generate with ChatGPT OAuth
Budget-conscious?     → FLUX or SD locally (GPU cost only)
```

## Cloud APIs

### GPT Image 2 (OpenAI)

In OpenCode, ask naturally for an image and include the desired project-relative
output path. The aidevops plugin exposes `gpt_image_generate` automatically.

```text
Generate a low-quality 1024x1024 watercolor lighthouse draft and save it to assets/lighthouse.png.
```

PNG is the default. Select `format: "jpeg"` or `format: "webp"` for another
native raster format; the output path must use the matching `.jpg`/`.jpeg` or
`.webp` extension. SVG and PDF belong to artifact/document workflows and are not
GPT Image output formats.

The tool defaults to the existing ChatGPT OAuth pool. Add an account through the
recommended device OAuth flow with `aidevops model-accounts-pool add openai`.
An optional OAuth `account` pins the request to that pool email; a pinned account
never falls back to another login.

Platform API billing is always explicit and uses an account-specific secret:

```bash
aidevops secret set OPENAI_IMAGE_API_KEY_WORK
```

Then select `auth: "api"` and `account: "WORK"` in the tool call. To configure
a deliberate local default alias, set `AIDEVOPS_OPENAI_IMAGE_ACCOUNT=WORK`;
the tool still requires `auth: "api"`, so it cannot silently switch billing
from a subscription to API credits. Never paste an API key into chat.

| Parameter | Options | Notes |
|-----------|---------|-------|
| `format` | png, jpeg, webp | `png` is the default; output extension must match |
| `quality` | low, medium, high, auto | `auto` is the default; use low for drafts |
| `size` | auto or WIDTHxHEIGHT | Edges must be multiples of 16, max 3840px, ratio ≤3:1, total 655,360-8,294,400px |
| `images` | 0-8 project-relative paths | Reference-guided generation/editing; PNG, JPEG, or WebP, 20 MiB each |
| `auth` | oauth, api | OAuth is the default; API billing must be explicit |
| `account` | OAuth email or API alias | Exact selection only; no silent account substitution |

OAuth uses OpenCode's Codex channel and is therefore runtime-specific and
experimental. The public API route calls `gpt-image-2` directly. OpenCode V2
remains fail-closed until the aidevops V2 adapter implements equivalent tool,
permission, credential, and session contracts.

### Midjourney

No REST API — use Discord `/imagine` or [midjourney.com](https://www.midjourney.com/).

Flags: `--ar 16:9` (aspect) · `--v 6` (model) · `--style raw` (less stylised) · `--no text, watermark` (negatives)

### Google Imagen 3

```bash
curl -X POST \
  "https://us-central1-aiplatform.googleapis.com/v1/projects/$PROJECT_ID/locations/us-central1/publishers/google/models/imagen-3.0-generate-002:predict" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{"instances": [{"prompt": "..."}], "parameters": {"sampleCount": 1, "aspectRatio": "16:9"}}'
```

## Local Generation (ComfyUI)

```bash
git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI && pip install -r requirements.txt
# Download FLUX model (~12GB) to ComfyUI/models/checkpoints/
# https://huggingface.co/black-forest-labs/FLUX.1-dev
python main.py --listen 0.0.0.0 --port 8188
```

| Model | Min VRAM | Recommended |
|-------|----------|-------------|
| FLUX.1 [schnell] | 8GB | 12GB+ |
| FLUX.1 [dev] | 12GB | 16GB+ |
| SD XL | 6GB | 8GB+ |
| SD 3.5 | 8GB | 12GB+ |

**Headless API**:

```bash
curl -X POST http://localhost:8188/prompt -H "Content-Type: application/json" -d '{"prompt": <workflow-json>}'
curl http://localhost:8188/queue
curl "http://localhost:8188/view?filename=<output-filename>"
```

## Prompt Engineering

Structure: subject + style + lighting + composition + mood.

Example: `"A golden retriever puppy on red velvet, oil painting, soft natural light, close-up, warm and inviting"`

**Negative prompts (SD/FLUX)**:

```text
blurry, low quality, distorted, deformed, ugly, duplicate, watermark,
text, signature, oversaturated, underexposed, overexposed
```

**Batch generation**: invoke `gpt_image_generate` once per distinct asset. Each
call returns one native raster image and preserves an existing output by choosing
a versioned filename. Avoid unattended high-quality batches because API and
subscription usage limits still apply.

## See Also

- `overview.md` - Vision AI category overview
- `image-editing.md` - Modify existing images
- `image-understanding.md` - Analyse existing images
- `tools/video/video-prompt-design.md` - Video prompt engineering (related techniques)
- `tools/infrastructure/cloud-gpu.md` - GPU deployment for local models
