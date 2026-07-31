---
name: audio
description: Audio production pipeline - voice, sound design, emotional cues, mixing
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Audio Production

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Pipeline**: Voice cleanup → Voice transformation → Sound design → Mixing
- **Key rule**: Clean AI voice in CapCut before ElevenLabs; raw AI audio amplifies artifacts
- **Pipeline helper**: `voice-pipeline-helper.sh [pipeline|extract|cleanup|transform|normalize|tts|voices|clone|status]`
- **Voice bridge**: `voice-helper.sh [talk|devices|voices|benchmark]`
- **References**: `tools/voice/speech-to-speech.md`, `voice-helper.sh`

<!-- AI-CONTEXT-END -->

## Voice Production Pipeline

Do not feed raw AI video audio directly to ElevenLabs.
1. **CapCut AI Voice Cleanup** — normalize accents and artifacts, remove robotic patterns, clean noise, standardize volume
2. **ElevenLabs Transformation** — add voice cloning, emotional delivery, and character consistency

**Alternative**: MiniMax TTS suits talking-head content where ElevenLabs is overkill. Cost baseline: $5/month for 120 minutes and a 10-second clip for voice clone. See `tools/voice/voice-models.md`.

### Voice Cloning

Do not use pre-made ElevenLabs voices for realistic content; they are widely recognized as AI-generated.

| Method | Input | Use |
|--------|-------|-----|
| Voice Design | Natural language description | e.g., "warm female voice, mid-30s, slight British accent" |
| Instant Clone | 10-30 second clean clip | Quick personas |
| Professional Clone | 3-5 minutes | AI influencer personas (highest fidelity) |

**Source quality**: single speaker, quiet environment, clear pronunciation. If cloning from existing content, run CapCut cleanup first. Keep one voice model across the channel; refresh samples quarterly.

### Emotional Block Cues

Use emotion tags with engines that support them (ElevenLabs, ChatTTS). Scripts from `content/production-writing.md` should include this markup.

```text
[neutral]Welcome.[/neutral] [excited]Today we're covering something amazing![/excited] [serious]But first, the problem.[/serious]
```

| Tag | Use Case | Pacing Position |
|-----|----------|-----------------|
| `[excited]` | Hooks, reveals, wins | Hook (0-3s), CTA (final 5s) |
| `[curious]` | Questions, exploration | Hook (0-3s) |
| `[serious]` | Problems, warnings, data | Problem (3-10s) |
| `[empathetic]` | Pain points, struggles | Problem (3-10s) |
| `[confident]` | Authority, expertise | Solution (10s+) |
| `[urgent]` | CTAs, time-sensitive | CTA (final 5s) |
| `[neutral]` | Default, informational | Any |

## Audio Design Layers

| Layer | Target LUFS | Processing / Notes |
|-------|-------------|-------------------|
| **1: Dialogue** (primary) | -15 | `Raw Voice → Noise Reduction → EQ → Compression → De-esser → Limiter`. Keep centered. EQ: high-pass 80Hz, presence boost 3-5kHz. Tools: CapCut, ElevenLabs, Audacity/Audition, `voice-helper.sh` |
| **2: Ambient** | -25 | Use stereo width for immersion and low-pass filtering so ambience does not compete with dialogue. Sources: Freesound.org (CC0), Epidemic Sound, AudioCraft, Stable Audio |
| **3: SFX** | -10 to -20 | Whooshes, impacts, UI sounds, foley, risers, drops. Land 1-2 frames before the visual event. Layer larger impacts and match reverb to dialogue space |
| **4: Music** | -18 to -20 | Sidechain dialogue into music. Threshold -20dB, ratio 4:1, attack 10ms, release 200ms. Sources: Epidemic Sound, Artlist, Uppbeat, Suno, Udio |

| Content Type | Ambient | Music Style | Ducking |
|--------------|---------|-------------|---------|
| UGC/Vlog | Diegetic only (room tone) | None | N/A |
| Tutorial | Minimal/none | Minimal, ambient | -6dB |
| Commercial | Designed ambience | Mixed diegetic + score | -8dB |
| Documentary | Rich environmental | Cinematic score | -4dB |
| YouTube | — | Upbeat, royalty-free | -6dB |

## Loudness Reference

| Platform | Target LUFS | Notes |
|----------|-------------|-------|
| YouTube | -14 to -16 | Normalizes to -14 |
| Podcast | -16 to -19 | Spotify normalizes to -14 |
| TikTok/Shorts | -10 to -12 | Louder for mobile |
| Broadcast TV | -23 to -24 | EBU R128 |
| Streaming (Netflix) | -27 | Wide dynamic range |
| Audiobook | -18 to -23 | Consistent, comfortable |

```bash
ffmpeg -i input.mp4 -af loudnorm=print_format=json -f null -
# Audacity: Analyze > Loudness Normalization (preview mode)
# DaVinci Resolve: Fairlight > Loudness Meter
```

**Normalization workflow**: mix layers, measure integrated LUFS, normalize, then limit to true peak -1dB.

## Voice Tools

```bash
voice-helper.sh talk                        # Start voice conversation (defaults)
voice-helper.sh talk whisper-mlx edge-tts  # Explicit engines
voice-helper.sh talk whisper-mlx macos-say # Offline mode
voice-helper.sh devices                     # List audio devices
voice-helper.sh voices                      # List available TTS voices
voice-helper.sh benchmark                   # Test component speeds
```

**Architecture**: `Mic → Silero VAD → Whisper MLX (1.4s) → Claude Code run --attach (~4-6s) → Edge TTS (0.4s) → Speaker`. Round-trip: ~6-8s conversational, longer with tool execution.

| Service | Details | CLI |
|---------|---------|-----|
| ElevenLabs | Voice cloning (3-5 minute sample), 29 languages, emotional control | `voice-pipeline-helper.sh [transform\|tts\|voices\|clone]` |
| Local ffmpeg | Noise reduction, high-pass, de-essing, loudness normalization | `voice-pipeline-helper.sh cleanup <audio> [output] [target-lufs]` |
| Edge TTS (free) | 400+ voices, 100+ languages, no API key | Used by `voice-helper.sh` |

## See Also

- `content/media-generation-providers.md` — Hosted/local media provider routing
- `content/video-kie.md` — Kie.ai audio models through the generic Market task API
- `tools/voice/speech-to-speech.md` — Advanced voice pipeline (VAD, STT, LLM, TTS)
- `tools/voice/cloud-voice-agents.md` — Cloud voice agents (GPT-4o Realtime, MiniCPM-o)
- `tools/voice/voice-ai-models.md` — Complete model comparison (TTS, STT, S2S)
- `tools/voice/voice-models.md` — TTS model comparison (ElevenLabs, MiniMax, Qwen3-TTS)
- `tools/voice/pipecat-opencode.md` — Pipecat real-time voice pipeline
- `content/production-writing.md` — Script structure, dialogue pacing, emotional cues
- `content/production-video.md` — Video production and audio sync
- `content/optimization.md` — A/B testing audio variants
