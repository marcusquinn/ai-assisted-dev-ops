---
description: "Runway API - AI video, image, and audio generation (Gen-4, Veo 3, Act Two, ElevenLabs)"
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

# Runway API

AI video, image, and audio generation via REST API. Official Node.js and Python SDKs.

**Base URL**: `https://api.dev.runwayml.com` | **Version**: `X-Runway-Version: 2024-11-06` | **1 credit = $0.01**

## Authentication

```bash
Authorization: Bearer $RUNWAYML_API_SECRET
aidevops secret set RUNWAYML_API_SECRET
```

SDKs read `RUNWAYML_API_SECRET` automatically.

## Endpoints

| Endpoint | Purpose | Models | Cost |
|----------|---------|--------|------|
| `POST /v1/image_to_video` | Image→video | `gen4_turbo` (5cr/s), `veo3`/`veo3.1` (40cr/s), `veo3.1_fast` (15cr/s) | per-second |
| `POST /v1/text_to_video` | Text→video | `veo3`, `veo3.1` (40cr/s audio, 20 no-audio), `veo3.1_fast` (15/10) | per-second |
| `POST /v1/video_to_video` | Video→video | `gen4_aleph` (15cr/s) | per-second |
| `POST /v1/text_to_image` | Text/image→image | `gen4_image` (5cr 720p, 8cr 1080p), `gen4_image_turbo` (2cr), `gemini_2.5_flash` (5cr) | per-image |
| `POST /v1/character_performance` | Character control | `act_two` (5cr/s) | per-second |
| `POST /v1/text_to_speech` | TTS | `eleven_multilingual_v2` (1cr/50 chars) | per-char |
| `POST /v1/speech_to_speech` | Voice conversion | `eleven_multilingual_sts_v2` (1cr/3s) | per-second |
| `POST /v1/sound_effect` | SFX generation | `eleven_text_to_sound_v2` (1cr/s) | per-second |
| `POST /v1/voice_dubbing` | Multi-lang dub | `eleven_voice_dubbing` (1cr/2s output) | per-second |
| `POST /v1/voice_isolation` | Isolate voice | `eleven_voice_isolation` (1cr/6s) | per-second |
| `GET /v1/tasks/{id}` | Poll task status | -- | -- |
| `DELETE /v1/tasks/{id}` | Cancel/delete task | -- | -- |
| `POST /v1/uploads` | Upload ephemeral file | -- | -- |
| `GET /v1/organization` | Org info + credits | -- | -- |
| `POST /v1/organization/usage` | Credit usage query | -- | -- |

## Image-to-Video (Gen-4 Turbo)

```bash
curl -X POST https://api.dev.runwayml.com/v1/image_to_video \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $RUNWAYML_API_SECRET" \
  -H "X-Runway-Version: 2024-11-06" \
  -d '{"model":"gen4_turbo","promptImage":"https://example.com/image.jpg","promptText":"A timelapse on a sunny day","ratio":"1280:720","duration":5}'
```

> Subsequent curl examples omit the three standard headers for brevity.

SDK pattern (identical across all endpoints — shown once):

```javascript
const task = await client.imageToVideo.create({
  model: 'gen4_turbo', promptImage: 'https://example.com/image.jpg',
  promptText: 'A timelapse on a sunny day', ratio: '1280:720', duration: 5,
}).waitForTaskOutput();
```

```python
task = client.image_to_video.create(
    model='gen4_turbo', prompt_image='https://example.com/image.jpg',
    prompt_text='A timelapse on a sunny day', ratio='1280:720', duration=5,
).wait_for_task_output()
```

**Params**: `model` (required), `promptImage` (HTTPS URL/data URI/runway:// URI), `promptText` (<=1000 chars), `ratio` (required), `duration` (2-10s), `seed` (0-4294967295)

**Gen-4 Turbo ratios**: `1280:720`, `1584:672`, `1104:832`, `720:1280`, `832:1104`, `960:960`

## Text-to-Video (Veo 3/3.1)

```bash
curl -X POST https://api.dev.runwayml.com/v1/text_to_video \
  -d '{"model":"veo3.1","promptText":"A cinematic mountain landscape at golden hour","ratio":"1920:1080","duration":8,"audio":true}'
```

**Params**: `model` (`veo3`/`veo3.1`/`veo3.1_fast`), `promptText` (<=1000 chars, required), `ratio` (`1280:720`/`720:1280`/`1080:1920`/`1920:1080`), `duration` (4/6/8s), `audio` (bool, default true — affects pricing)

## Video-to-Video (Gen-4 Aleph)

```bash
curl -X POST https://api.dev.runwayml.com/v1/video_to_video \
  -d '{"model":"gen4_aleph","videoUri":"https://example.com/input.mp4","promptText":"Add dramatic lighting","references":[{"type":"image","uri":"https://example.com/style.jpg"}]}'
```

**Params**: `model` (`gen4_aleph`), `videoUri` (required), `promptText` (<=1000 chars, required), `references` (<=1 image), `seed`

## Text/Image to Image (Gen-4 Image)

Use `@tag` in prompts to reference tagged images.

```bash
curl -X POST https://api.dev.runwayml.com/v1/text_to_image \
  -d '{"model":"gen4_image","promptText":"@subject in a cyberpunk city","ratio":"1920:1080","referenceImages":[{"uri":"https://example.com/person.jpg","tag":"subject"}]}'
```

**Params**: `model`, `promptText` (<=1000 chars, use `@tag` for refs), `ratio`, `referenceImages` (1-3 with `uri` + optional `tag`), `seed`

**Gen-4 Image ratios**: `1024:1024`, `1080:1080`, `720:720`, `1168:880`, `1360:768`, `1440:1080`, `1808:768`, `1920:1080`, `2112:912`, `1280:720`, `960:720`, `1680:720`, `1080:1440`, `1080:1920`, `720:1280`, `720:960`

## Character Performance (Act Two)

```javascript
const task = await client.characterPerformance.create({
  model: 'act_two',
  character: { type: 'image', uri: 'https://example.com/character.jpg' },
  reference: { type: 'video', uri: 'https://example.com/performance.mp4' },
  ratio: '1280:720', bodyControl: true, expressionIntensity: 4,
}).waitForTaskOutput();
```

**Params**: `model` (`act_two`), `character` (`{type:"image"/"video",uri}`), `reference` (`{type:"video",uri}` 3-30s), `bodyControl` (bool), `expressionIntensity` (1-5, default 3), `ratio`

## Audio

### Text-to-Speech

```javascript
const task = await client.textToSpeech.create({
  model: 'eleven_multilingual_v2',
  promptText: 'The quick brown fox jumps over the lazy dog',
  voice: { type: 'runway-preset', presetId: 'Leslie' },
}).waitForTaskOutput();
```

**Presets**: Maya, Arjun, Serene, Bernard, Billy, Mark, Clint, Mabel, Chad, Leslie, Eleanor, Elias, Elliot, Grungle, Brodie, Sandra, Kirk, Kylie, Lara, Lisa, Malachi, Marlene, Martin, Miriam, Monster, Paula, Pip, Rusty, Ragnar, Xylar, Maggie, Jack, Katie, Noah, James, Rina, Ella, Mariah, Frank, Claudia, Niki, Vincent, Kendrick, Myrna, Tom, Wanda, Benjamin, Kiana, Rachel

### Speech-to-Speech

```javascript
const task = await client.speechToSpeech.create({
  model: 'eleven_multilingual_sts_v2',
  media: { type: 'audio', uri: 'https://example.com/audio.mp3' },
  voice: { type: 'runway-preset', presetId: 'Maggie' },
  removeBackgroundNoise: true,
}).waitForTaskOutput();
```

### Sound Effects

```javascript
const task = await client.soundEffect.create({
  model: 'eleven_text_to_sound_v2',
  promptText: 'A thunderstorm with heavy rain',
  duration: 10, loop: true,
}).waitForTaskOutput();
```

**Params**: `promptText` (<=3000 chars), `duration` (0.5-30s, auto if omitted), `loop` (bool)

### Voice Dubbing

```javascript
const task = await client.voiceDubbing.create({
  model: 'eleven_voice_dubbing',
  audioUri: 'https://example.com/audio.mp3',
  targetLang: 'es',
}).waitForTaskOutput();
```

**Params**: `audioUri`, `targetLang` (en/hi/pt/zh/es/fr/de/ja/ar/ru/ko/id/it/nl/tr/pl/sv/fil/ms/ro/uk/el/cs/da/fi/bg/hr/sk/ta), `disableVoiceCloning`, `dropBackgroundAudio`, `numSpeakers`

### Voice Isolation

```javascript
const task = await client.voiceIsolation.create({
  model: 'eleven_voice_isolation',
  audioUri: 'https://example.com/audio.mp3',
}).waitForTaskOutput();
```

Input duration: 4.6s-3600s.

## Task Management

All generation endpoints return a task ID (async). Poll at 5+ second intervals with jitter and exponential backoff.

**Statuses**: `PENDING`, `THROTTLED`, `RUNNING`, `SUCCEEDED`, `FAILED`

```bash
# Poll
curl https://api.dev.runwayml.com/v1/tasks/{task_id} \
  -H "Authorization: Bearer $RUNWAYML_API_SECRET" -H "X-Runway-Version: 2024-11-06"

# Cancel
curl -X DELETE https://api.dev.runwayml.com/v1/tasks/{task_id} \
  -H "Authorization: Bearer $RUNWAYML_API_SECRET" -H "X-Runway-Version: 2024-11-06"
```

SDKs: `.waitForTaskOutput()` / `.wait_for_task_output()` (10-min default timeout). Errors: `TaskFailedError` (check `.taskDetails`), `TaskTimedOutError`.

```javascript
import { TaskFailedError } from '@runwayml/sdk';
try {
  const task = await client.imageToVideo
    .create({ model: 'gen4_turbo', promptImage: '...', ratio: '1280:720' })
    .waitForTaskOutput({ timeout: 5 * 60 * 1000 });
} catch (error) {
  if (error instanceof TaskFailedError) console.error('Failed:', error.taskDetails);
}
```

## File Uploads

```javascript
import fs from 'node:fs';
const uploadUri = await client.uploads.createEphemeral(fs.createReadStream('./input.mp4'));
```

Ephemeral uploads expire after 24h. Use `uploadUri` in `videoUri`, `promptImage`, etc.

## Input Requirements

| Type | Formats | URL limit | Data URI limit | Upload limit |
|------|---------|-----------|----------------|--------------|
| Images | JPEG, PNG, WebP (no GIF) | 16MB | 5MB | 200MB |
| Videos | MP4 (H.264/H.265/AV1), MOV, MKV, WebM | 32MB | 16MB | 200MB |
| Audio | MP3, WAV, FLAC, M4A (AAC/ALAC), AAC | 32MB | 16MB | 200MB |

Min image: 640x640px, max: 4K. Base64 ~33% overhead (5MB data URI ≈ 3.3MB binary).

## Organization & Credits

```javascript
const details = await client.organization.retrieve();
console.log(details.creditBalance);

const usage = await client.organization.retrieveUsage({ startDate: '2026-01-01', beforeDate: '2026-02-01' });
```

## Content Moderation

```json
{"contentModeration": {"publicFigureThreshold": "low"}}
```

Set `"low"` for less strict public figure recognition.

## Error Codes

| Code | Meaning |
|------|---------|
| 200 | Task created |
| 400 | Bad request |
| 401 | Invalid API key |
| 404 | Task not found |
| 429 | Rate limited |

## Helper Script

```bash
runway-helper.sh credits
runway-helper.sh video --image https://example.com/photo.jpg --prompt "Camera pans" --model gen4_turbo --ratio 1280:720 --duration 5
runway-helper.sh video --prompt "A cinematic mountain landscape" --model veo3.1 --ratio 1920:1080 --duration 8
runway-helper.sh image --prompt "@subject in a garden" --ref https://example.com/person.jpg:subject --model gen4_image --ratio 1920:1080
runway-helper.sh tts --text "Hello world" --voice Leslie
runway-helper.sh sts --audio https://example.com/audio.mp3 --voice Maggie
runway-helper.sh sfx --prompt "A thunderstorm with heavy rain" --duration 10
runway-helper.sh dub --audio https://example.com/audio.mp3 --lang es
runway-helper.sh isolate --audio https://example.com/audio.mp3
runway-helper.sh status {task-id}
runway-helper.sh cancel {task-id}
runway-helper.sh usage --start 2026-01-01 --end 2026-02-01
```

## Provider Selection

Use `content/media-generation-providers.md` for the canonical provider
comparison. Choose Runway when its direct media pipeline, account, official
Node.js/Python SDKs, or provider-specific task behaviour is required. Use a
gateway only when broader model access outweighs direct-provider semantics.

## Related

- `content/media-generation-providers.md` - Canonical provider routing
- `content/video-kie.md` - Kie.ai generic Market task API
- `content/video-higgsfield.md` - Higgsfield API (alternative multi-model platform)
- `tools/video/video-prompt-design.md` - Video prompt engineering
- `content/production-video.md` - Video production pipeline
- `tools/vision/image-generation.md` - Image generation overview
