---
description: "Vision AI tools overview - image generation, understanding, and editing model selection"
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Vision AI Tools

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Route by task**: generate → `image-generation.md`; analyze → `image-understanding.md`; edit → `image-editing.md`; tiled image mosaic / photo mosaic / collage wallpaper / image grid background / mozaic → `image-mosaic-skill.md`
- **Create**: GPT Image 2 via `gpt_image_generate`, Midjourney, FLUX, Stable Diffusion
- **Analyze**: GPT-4o vision, Claude vision, Gemini, LLaVA, Qwen-VL
- **Edit**: GPT Image 2 reference editing, Stable Diffusion inpaint, FLUX fill
- **Local stack**: Ollama for VLMs, ComfyUI for generation/editing, `tools/infrastructure/cloud-gpu.md` for GPU deployment
- **Specialized routes**: OCR → `tools/ocr/glm-ocr.md`; GUI screenshots → `tools/browser/peekaboo.md`

<!-- AI-CONTEXT-END -->

## Selection Guide

| Need | Route | Best Options | Deployment Notes |
|------|-------|--------------|------------------|
| Text-to-image, concept art, marketing assets | `image-generation.md` | GPT Image 2, Midjourney, FLUX, Stable Diffusion | OpenCode uses OAuth-first `gpt_image_generate`; ComfyUI gives local control |
| Tiled image mosaic, photo mosaic, collage wallpaper, image grid background, mozaic | `image-mosaic-skill.md` | Approved source photos, square cover-crops, deterministic raster tiles | Use 200px square tiles for recognisable photos; smaller tiles only for texture grids |
| Image analysis, captioning, visual Q&A | `image-understanding.md` | GPT-4o vision, Claude vision, Gemini, LLaVA, Qwen-VL | Ollama fits privacy-sensitive local analysis; cloud models fit large-context reasoning |
| Inpainting, outpainting, style transfer | `image-editing.md` | GPT Image 2 references, Stable Diffusion inpaint, FLUX fill | Use ComfyUI when pixel-specific masks are required |
| Product photos / marketing visuals | `image-generation.md` | GPT Image 2 (cloud), FLUX (local) | Choose cloud for speed, local for cost/control |
| Code screenshots, diagrams, alt text | `image-understanding.md` | Claude vision, GPT-4o vision, Gemini, LLaVA | Gemini and GPT-4o fit large diagrams; LLaVA fits local captioning |
| Documents, receipts, GUI screenshots | `tools/ocr/glm-ocr.md` or `tools/browser/peekaboo.md` | GLM-OCR, Peekaboo | Prefer dedicated OCR or browser capture flows over general VLM analysis |
| Background removal, upscaling, enhancement | `image-editing.md` | Stable Diffusion inpaint, GPT Image 2, Real-ESRGAN, Topaz | Local tools are strongest for enhancement workflows |

## Deployment Options

| Deployment | Models | Best For |
|------------|--------|----------|
| **Cloud API** | GPT Image 2, GPT-4o vision, Claude vision, Gemini, Midjourney | Fast integration, no GPU needed |
| **Local (Ollama)** | LLaVA, MiniCPM-o, Qwen-VL | Private understanding tasks, no API cost |
| **Local (ComfyUI)** | FLUX, Stable Diffusion XL, ControlNet | Generation, editing, workflow control |
| **Cloud GPU** | Any model via vLLM/ComfyUI | Scale, large local models, batch processing |

## Related aidevops Routes

- `tools/ocr/glm-ocr.md` — dedicated OCR for text extraction
- `tools/browser/peekaboo.md` — screen capture plus vision analysis for GUI automation
- `tools/vision/image-mosaic-skill.md` — reusable real-image tiled mosaic and collage wallpaper pipeline
- `tools/video/` — image-to-video pipelines (Kling, Seedance via Higgsfield)
- `tools/infrastructure/cloud-gpu.md` — GPU deployment for local vision models
- `content/` — AI-generated images for content workflows
