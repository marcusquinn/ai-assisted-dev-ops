<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Related Tools & Resources

## Internal References

- `.agents/content/media-generation-providers.md` — Canonical hosted/local provider routing
- `.agents/content/video-kie.md` — Kie.ai image/video/audio Market API
- `.agents/tools/video/video-prompt-design.md` — Veo 3 Meta Framework (7-component prompting)
- `.agents/content/video-higgsfield.md` — Higgsfield API integration
- `.agents/content/heygen-skill.md` — HeyGen Avatar API (talking-head generation)
- `.agents/content/video-muapi.md` — MuAPI (VEED lipsync, face swap, VFX)
- `.agents/tools/video/remotion.md` — Programmatic video editing
- `.agents/tools/voice/voice-models.md` — TTS model comparison (ElevenLabs, MiniMax, Qwen3-TTS)
- `.agents/tools/voice/qwen3-tts.md` — Qwen3-TTS setup and voice cloning
- `.agents/content/production-image.md` — Image generation (Nanobanana Pro, Midjourney, Freepik)
- `.agents/content/production-audio.md` — Voice pipeline, 4-Layer Audio Design
- `.agents/content/production-characters.md` — Character consistency (Facial Engineering, Character Bibles)
- `.agents/content/optimization.md` — A/B testing, seed bracketing automation
- `.agents/scripts/seed-bracket-helper.sh` — Seed bracketing CLI

## Helper Scripts

```bash
# Seed bracketing
seed-bracket-helper.sh generate --type product --prompt "Product rotating on white background"
seed-bracket-helper.sh list    # Show all bracket runs
seed-bracket-helper.sh status  # Check progress of latest run
seed-bracket-helper.sh score 4005 8 9 7 8 9 && seed-bracket-helper.sh report

# Unified video generation CLI (Sora 2, Veo 3.1, Nanobanana Pro)
video-gen-helper.sh generate sora "A cat reading a book" sora-2-pro 8 1280x720
video-gen-helper.sh generate veo "Cinematic mountain sunset" veo-3.1-generate-001 16:9
video-gen-helper.sh character /path/to/face.jpg
video-gen-helper.sh bracket "Product demo" https://example.com/product.jpg 4000 4010 dop-turbo
video-gen-helper.sh status sora vid_abc123 && video-gen-helper.sh download sora vid_abc123 ./output
video-gen-helper.sh models

# Kie.ai generic Market tasks (model-specific JSON remains pass-through)
kie-helper.sh video --model kling-3.0/video --prompt "A cat reading a book" \
  --params '{"duration":"5","aspect_ratio":"16:9","mode":"pro","sound":true,"multi_shots":false,"multi_prompt":[]}'
kie-helper.sh wait TASK_ID --timeout 900
```

## External Resources

- [Sora 2 Documentation](https://openai.com/sora)
- [Veo 3.1 Documentation](https://deepmind.google/technologies/veo/)
- [Higgsfield Platform](https://platform.higgsfield.ai)
- [HeyGen Platform](https://www.heygen.com/)
- [Kie.ai Market](https://kie.ai/market)
- [Topaz Video AI](https://www.topazlabs.com/topaz-video-ai)
