---
description: "Image editing - AI-powered inpainting, outpainting, upscaling, and style transfer"
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

# Image Editing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Modify existing images — inpainting, outpainting, upscaling, style transfer, background removal, batch edits
- **Cloud**: GPT Image 2, Google Imagen edit, Adobe Firefly
- **Local**: Stable Diffusion inpaint, FLUX fill, Real-ESRGAN (upscaling), ControlNet
- **Workflow tool**: ComfyUI (node-based pipelines for complex edits)

<!-- AI-CONTEXT-END -->

## Editing Capabilities

| Capability | Description | Best Tool |
|------------|-------------|-----------|
| **Inpainting** | Replace selected region with AI content | SD inpaint, GPT Image 2 |
| **Outpainting** | Extend image beyond original boundaries | SD outpaint, FLUX fill |
| **Upscaling** | Increase resolution with AI enhancement | Real-ESRGAN, Topaz |
| **Background removal** | Remove or replace backgrounds | rembg, Segment Anything |
| **Style transfer** | Apply artistic style to existing image | SD img2img, ControlNet |
| **ControlNet** | Guide generation with edge/depth/pose maps | SD XL + ControlNet |
| **Face restoration** | Enhance/restore faces in images | GFPGAN, CodeFormer |

## Cloud APIs

### GPT Image 2 Reference Editing (OpenAI)

The OpenCode `gpt_image_generate` tool accepts up to 8 project-relative
reference images through `images`. Describe each image's role in the prompt.
ChatGPT OAuth is the default billing route; explicit `auth: "api"` uses the
named `OPENAI_IMAGE_API_KEY_<ACCOUNT>` secret and OpenAI's Images edit endpoint.
GPT Image 2 processes references at high fidelity automatically.

```text
Using refs/product.png as the product reference, place it on a clean marble counter in soft morning light. Save to assets/product-morning.png.
```

The current aidevops tool supports reference-guided edits, not mask inpainting.
Use a dedicated local inpainting workflow when pixel-specific masks are needed.

### Google Imagen Edit (Vertex AI)

```bash
curl -X POST "https://us-central1-aiplatform.googleapis.com/v1/projects/$PROJECT_ID/locations/us-central1/publishers/google/models/imagen-3.0-capability-001:predict" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "Content-Type: application/json" \
  -d '{"instances": [{"prompt": "Replace with a modern office", "image": {"bytesBase64Encoded": "<base64>"}, "mask": {"image": {"bytesBase64Encoded": "<base64>"}}}], "parameters": {"sampleCount": 1}}'
```

## Local Tools

### Stable Diffusion Inpainting (ComfyUI)

```bash
git clone https://github.com/comfyanonymous/ComfyUI.git && cd ComfyUI && pip install -r requirements.txt
# SD XL inpaint model → models/checkpoints/ (https://huggingface.co/diffusers/stable-diffusion-xl-1.0-inpainting-0.1)
python main.py --listen 0.0.0.0 --port 8188  # web UI includes mask painting
```

### Real-ESRGAN (Upscaling)

```bash
pip install realesrgan
python -m realesrgan -i input.jpg -o output.jpg -s 4                 # 4x upscale
python -m realesrgan -i input.jpg -o output.jpg -s 4 --face_enhance  # + face enhancement
```

Scales: **2x** (fast) · **4x** (standard) · **8x** (max, may artifact)

### rembg (Background Removal)

```bash
pip install rembg[gpu]  # or `rembg` for CPU-only
rembg i input.jpg output.png      # single image
rembg p input_dir/ output_dir/    # batch
rembg i -a input.jpg output.png   # alpha matting (better edges)
```

### GFPGAN (Face Restoration)

`pip install gfpgan && python -m gfpgan.inference -i input.jpg -o output/ -v 1.4 -s 2`

### ControlNet (Guided Generation)

Structural guides for precise control. Used within ComfyUI or Automatic1111.

| Control Type | Input | Use Case |
|-------------|-------|----------|
| **Canny edge** | Edge map | Preserve structure, change style |
| **Depth** | Depth map | Maintain spatial layout |
| **OpenPose** | Pose skeleton | Control character poses |
| **Scribble** | Hand-drawn sketch | Sketch to image |
| **Segmentation** | Semantic map | Control scene composition |
| **Tile** | Low-res image | Upscale with detail generation |

## Common Workflows

### Product Photo Enhancement

`rembg` → Real-ESRGAN 2x (if needed) → SD inpaint / GPT Image 2 (new background) → ImageMagick / Pillow (colour correct)

### Batch Background Removal

```bash
mkdir -p out && for img in input/*.{jpg,png,webp}; do [ -f "$img" ] && rembg i "$img" "out/$(basename "${img%.*}").png"; done
```

### Image Resize and Optimise (ImageMagick)

```bash
magick input.jpg -resize 1920x\> -quality 85 output.jpg               # resize, keep aspect
magick input.jpg -resize 1920x\> -quality 80 output.webp              # to WebP
magick mogrify -resize 1920x\> -quality 85 -path output/ input/*.jpg  # batch
```

## VRAM Requirements

| Tool | Min VRAM | Recommended | Notes |
|------|----------|-------------|-------|
| SD XL inpaint | 6GB | 8GB+ | Standard inpainting |
| FLUX fill | 12GB | 16GB+ | Higher quality |
| ControlNet | 8GB | 12GB+ | Adds ~2GB to base model |
| Real-ESRGAN | 2GB | 4GB+ | Lightweight |
| rembg (GPU) | 2GB | 4GB+ | Fast with GPU |
| GFPGAN | 2GB | 4GB+ | Face-specific |

**See also**: `overview.md` · `image-generation.md` · `image-understanding.md` · `tools/infrastructure/cloud-gpu.md` (cloud GPU deployment) · `tools/video/`
