---
name: image
description: AI image generation, thumbnails, style libraries, and visual asset production
mode: subagent
model: standard
tools:
  read: true
  write: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Image Production

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Tools**: Nanobanana Pro (JSON prompts), Midjourney (objects/environments), Freepik (characters), Seedream 4 (4K refinement), Ideogram (face swap)
- **Techniques**: Style library, annotated frame-to-video, Shotdeck references, thumbnail factory
- **Related**: `tools/vision/image-generation.md`, `content/production-video.md`, `content/optimization.md`

<!-- AI-CONTEXT-END -->

## Tool Routing

```text
Structured JSON control?        → Nanobanana Pro
Objects/environments?           → Midjourney (--ar 16:9 --style raw)
Character-driven scenes?        → Freepik
4K refinement/upscaling?        → Seedream 4
Face swap/consistency?          → Ideogram
Text in images?                 → DALL-E 3 or Ideogram
Local/open-source?              → FLUX.1 or SD XL (tools/vision/image-generation.md)
```

## Tool-Specific Prompting

**Midjourney**: `[SUBJECT] [ACTION] in [ENVIRONMENT], [LIGHTING], [STYLE], [CAMERA], --ar 16:9 --style raw --v 6 --no text, watermark` — always `--style raw` for production.

**Freepik**: Character-driven scenes (team photos, lifestyle, testimonials). Specify demographics, emotion, environment, style.

**Seedream 4**: Post-processing upscale after initial generation. 4K print/video prep. Only refine images that passed quality checks.

**Ideogram**: Face swap for character consistency. Generate base portrait, upload as reference, generate new scenes, swap. Alt: `content/production-characters.md` (Facial Engineering Framework).

## Nanobanana Pro JSON Schema

Save working JSON as named templates; swap `subject`/`concept`, keep brand consistency.

```json
{
  "subject": "Primary subject with physical details",
  "concept": "Creative direction or theme",
  "composition": { "framing": "close-up|medium|wide|extreme wide", "angle": "eye-level|low|high|dutch|bird's eye|worm's eye", "rule_of_thirds": true, "focal_point": "where eye lands", "depth_of_field": "shallow|medium|deep" },
  "lighting": { "type": "natural|studio|dramatic|soft|hard|rim|backlit", "direction": "front|side|back|top|bottom|three-point", "quality": "soft diffused|harsh direct|golden hour|blue hour|overcast", "color_temperature": "warm 3000K|neutral 5500K|cool 7000K", "mood": "bright airy|dark moody|high contrast|low contrast" },
  "color": { "palette": ["#HEX1","#HEX2","#HEX3"], "dominant": "#HEX", "accent": "#HEX", "saturation": "vibrant|muted|desaturated|monochrome", "harmony": "complementary|analogous|triadic|monochromatic" },
  "style": { "aesthetic": "photorealistic|cinematic|editorial|minimalist|maximalist|vintage|modern", "texture": "smooth|grainy|film grain|digital clean", "post_processing": "none|light grading|heavy grading|film emulation", "reference": "photographer/artist to emulate" },
  "technical": { "camera": "Sony A7IV|Canon R5|RED Komodo|iPhone 15 Pro", "lens": "24mm f/1.4|50mm f/1.8|85mm f/1.2|16-35mm f/2.8", "settings": "f/2.8, 1/250s, ISO 400", "resolution": "4K|8K|web-optimized", "aspect_ratio": "16:9|9:16|1:1|4:5" },
  "negative": "blurry, low quality, distorted, watermark, text, etc."
}
```

### Template Variants

Swap `subject`, `concept`, `focal_point` per shot; keep lighting/color/style constant.

| Template | Use for | Camera / Lens | Aspect |
|----------|---------|---------------|--------|
| **Editorial Portrait** | Headshots, author bios | Canon R5, 85mm f/1.2, studio 3-point, 5500K | 4:5 |
| **Environmental Product** | E-commerce, lifestyle | Sony A7IV, 50mm f/1.8, golden hour, 3500K | 16:9 |
| **Magazine Cover** | YouTube thumbnails, hero images | Canon R5, 85mm f/1.2, dramatic front+rim | 9:16 |
| **Street Photography** | Authentic lifestyle, UGC | Leica Q2, 28mm f/1.7, overcast, monochromatic | 3:2 |

## Thumbnail Factory

```bash
thumbnail-helper.sh generate "Your Video Topic" --count 10 --template high-contrast-face
thumbnail-helper.sh batch-score ~/.cache/aidevops/thumbnails/[output_dir]/
thumbnail-helper.sh ab-test VIDEO_ID ~/.cache/aidevops/thumbnails/[output_dir]/
thumbnail-helper.sh analyze VIDEO_ID
```

**Templates**: `high-contrast-face`, `text-heavy`, `before-after`, `curiosity-gap`, `product-showcase`, `cinematic`, `minimalist`, `action-packed`

**Best practices**: Faces increase CTR 30-40% (close-up, clear emotion). Readable at 320px. Leave 30% frame clear for title text. Surprised/excited/curious > neutral.

| Criterion | Weight | Check |
|-----------|--------|-------|
| **Face Prominence** | 25% | Visible, clear, emotionally expressive? |
| **Contrast** | 20% | Stands out in thumbnail grid? |
| **Text Space** | 15% | Clear space for title overlay? |
| **Brand Alignment** | 15% | Matches channel visual identity? |
| **Emotion** | 15% | Evokes curiosity, surprise, excitement? |
| **Clarity** | 10% | Readable at 320px? |

**Threshold**: 7.5+ only. Below = regenerate.

## Style Library

Save winning templates as `brand-thumbnail-v1.json`. Reuse by swapping `subject` and `concept`.

**Storage**: `~/.aidevops/.agent-workspace/work/[project]/style-library/` or version-control in content repo.

| Category | Use Case | Key Attributes |
|----------|----------|----------------|
| **Thumbnails** | YouTube, blog headers | High contrast, bold colors, centered, 16:9 |
| **Social Graphics** | Instagram, Twitter, LinkedIn | Platform aspect ratios, vibrant, clear focal point |
| **Product Shots** | E-commerce, reviews | Clean backgrounds, natural lighting |
| **Character Portraits** | About pages, team bios | Professional lighting, neutral backgrounds |
| **Lifestyle** | Blog content, storytelling | Environmental context, natural lighting |
| **Editorial** | Magazine-style content | Dramatic lighting, bold composition |

## Platform Specs

| Platform | Dimensions | Ratio | Notes |
|----------|------------|-------|-------|
| **YouTube Thumbnail** | 1280x720 | 16:9 | Max 2MB, high contrast |
| **Instagram Feed** | 1080x1080 | 1:1 | Square, vibrant |
| **Instagram Story** | 1080x1920 | 9:16 | Vertical, text-safe zones |
| **Twitter/X** | 1200x675 | 16:9 | Clear at small size |
| **LinkedIn** | 1200x627 | 1.91:1 | Professional aesthetic |
| **Pinterest** | 1000x1500 | 2:3 | Vertical, text overlay friendly |
| **Blog Header** | 1920x1080 | 16:9 | High res, SEO alt text |

**Formats**: JPG (photos), PNG (transparency/overlays), WebP (web).

## Color and Camera Reference

Specify exact hex codes (not "blue" or "warm tones"). Use [Coolors.co](https://coolors.co/) or [Adobe Color](https://color.adobe.com/).

| Harmony | When to Use | Palette |
|---------|-------------|---------|
| **Monochromatic** | Professional, minimalist | #2C3E50, #34495E, #5D6D7E |
| **Analogous** | Natural, cohesive | #FF6B35, #F7931E, #FDC830 |
| **Complementary** | High contrast, bold | #FF6B35, #004E89 |
| **Triadic** | Vibrant, balanced | #FF6B35, #4ECDC4, #C44569 |

| Use Case | Camera | Lens | Settings | Texture |
|----------|--------|------|----------|---------|
| **Portrait** | Canon R5 | 85mm f/1.2 | f/1.8, 1/200s, ISO 200 | smooth |
| **Product** | Sony A7IV | 50mm f/1.8 | f/2.8, 1/250s, ISO 400 | digital clean |
| **Landscape** | Nikon Z9 | 16-35mm f/2.8 | f/8, 1/125s, ISO 100 | digital clean |
| **Street** | Leica Q2 | 28mm f/1.7 | f/5.6, 1/500s, ISO 800 | film grain |
| **Cinematic** | RED Komodo 6K | 35mm f/1.4 | f/2.0, 1/50s, ISO 800 | film grain |

## Image-to-Video Workflows

### Annotated Frame-to-Video

1. **Generate base frame** — Nanobanana Pro or Midjourney (16:9, subject in starting position)
2. **Annotate** — arrows (direction), labels (action), timing markers. Color: red=character, blue=camera, green=object
3. **Feed to video model** — Veo 3.1 or Sora 2: "Animate this scene following the annotated motion indicators."
4. **Refine** — adjust annotations, regenerate if motion incorrect

See `content/production-video.md` for Veo 3.1 ingredients-to-video (NOT frame-to-video, which produces grainy output).

### Shotdeck Reference

1. Find reference on [Shotdeck](https://shotdeck.com/) by mood, genre, or visual style
2. Reverse-engineer with Gemini: "Analyze this cinematic frame. Describe composition, lighting, color palette (hex codes), camera settings, mood. Output as structured data."
3. Map analysis to Nanobanana JSON schema, adjust `subject`/`concept`, keep composition/lighting/color

## UGC Keyframe Template

Generate keyframe images per UGC storyboard shot. Each becomes a social image or frame-to-video reference. Extends Street Photography Template.

```json
{
  "subject": "[PRESENTER — identical across shots]",
  "concept": "[SHOT_PURPOSE from storyboard]",
  "composition": { "framing": "[CU hook/emotion, MS dialogue, WS context]", "angle": "eye-level", "rule_of_thirds": true, "focal_point": "[Per shot]", "depth_of_field": "shallow" },
  "lighting": { "type": "natural", "direction": "available light", "quality": "soft diffused", "color_temperature": "warm 4000K", "mood": "authentic and approachable" },
  "color": { "palette": ["[BRAND_PRIMARY]","[BRAND_SECONDARY]","[NEUTRAL]"], "dominant": "[BRAND_PRIMARY]", "accent": "[BRAND_SECONDARY]", "saturation": "muted", "harmony": "analogous" },
  "style": { "aesthetic": "photorealistic", "texture": "film grain", "post_processing": "film emulation", "reference": "iPhone 15 Pro casual photography" },
  "technical": { "camera": "iPhone 15 Pro", "lens": "24mm f/1.78", "settings": "f/1.78, 1/120s, ISO 640", "resolution": "4K", "aspect_ratio": "[9:16 TikTok/Reels | 16:9 YouTube]" },
  "negative": "studio lighting, professional setup, staged, posed, oversaturated, digital artifacts, watermark, text overlays, perfect skin retouching"
}
```

| Shot | Framing | Focal Point | Concept | Lighting |
|------|---------|-------------|---------|----------|
| 1: Hook | CU | Eyes | "Pattern interrupt — [hook]" | Warm natural, bright |
| 2: Before | MS | Presenter (frustrated) | "Pain point — [problem]" | Flat, desaturated |
| 3: Product Hero | CU to MS | Product in hands | "Product reveal — [name]" | Warm golden, product lit |
| 4: After | CU | Face (satisfied) | "Transformation — [outcome]" | Warm, rich, inviting |
| 5: CTA | MS | Presenter (direct) | "Call to action — [CTA]" | Clean, warm, confident |

**Batch**: Create base JSON, override `concept`/`framing`/`focal_point`/`lighting` per shot, batch generate, score (7.5+), assemble shot list, annotate for video, feed to Sora 2 Pro (UGC) or Veo 3.1 (cinematic).

## Enhancor AI Post-Processing

```bash
# Professional headshot enhancement
enhancor-helper.sh enhance --img-url https://example.com/headshot.jpg \
    --model enhancorv3 --type face --skin-refinement 60 \
    --skin-realism 1.2 --portrait-depth 0.25 --resolution 2048 \
    --area-background --sync -o professional_headshot.png

# Portrait upscale
enhancor-helper.sh upscale --img-url https://example.com/portrait.jpg \
    --mode professional --sync -o upscaled.png

# Batch processing
enhancor-helper.sh batch --command enhance --input photoshoot.txt \
    --output-dir enhanced/ --model enhancorv3 --skin-refinement 50 --resolution 2048
```

`skin_refinement_level` 40-60. `professional` mode for final deliverables. Only enhance images that passed quality checks. Full API: `content/video-enhancor.md`.

## References

| Topic | File |
|-------|------|
| Provider selection / hosted vs local generation | `content/media-generation-providers.md` |
| Kie.ai image generation and editing | `content/video-kie.md` |
| Brand identity / imagery style | `tools/design/brand-identity.md`, `context/brand-identity.toon` |
| Design catalogue (96 palettes, 67 UI styles) | `tools/design/ui-ux-catalogue.toon` |
| Model comparison (DALL-E 3, MJ, FLUX, SD XL) | `tools/vision/image-generation.md` |
| Video production / Veo 3.1 | `content/production-video.md` |
| Character consistency / Facial Engineering | `content/production-characters.md` |
| A/B testing / thumbnail analytics | `content/optimization.md` |
| UGC storyboard / hook formulas | `content/story.md` |
| 7-component video prompt format | `tools/video/video-prompt-design.md` |
| Portrait enhancement / Enhancor AI | `content/video-enhancor.md` |
| Vision AI decision tree | `tools/vision/overview.md` |
| Modify existing images | `tools/vision/image-editing.md` |
| Analyze images | `tools/vision/image-understanding.md` |
