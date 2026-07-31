---
description: Kie.ai unified Market API for asynchronous image, video, audio, uploads, callbacks, and credit-aware generation
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

# Kie.ai Market API

<!-- AI-CONTEXT-START -->

## Scope

Use Kie.ai when a task needs its shared Market API across image, video, or audio
models, especially when model-specific JSON pass-through, file uploads, account
credits, and asynchronous callbacks belong in one workflow.

Do not route here merely because a model exists in several gateways. First use
`content/media-generation-providers.md` to choose the provider. Prefer a direct
provider when the user requires its official SDK, support contract, account,
or provider-only feature. Prefer local ComfyUI when media cannot leave the
machine.

## Quick Reference

- **API**: `https://api.kie.ai`
- **Upload API**: `https://kieai.redpandaai.co`
- **Authentication**: `Authorization: Bearer $KIE_API_KEY`
- **CLI**: `kie-helper.sh`
- **Create**: `POST /api/v1/jobs/createTask`
- **Status**: `GET /api/v1/jobs/recordInfo?taskId=...`
- **Credits**: `GET /api/v1/chat/credit`
- **States**: `waiting`, `queuing`, `generating`, `success`, `fail`
- **Production completion**: prefer `callBackUrl`; verify HMAC signatures
- **Polling**: bounded exponential backoff, with a recoverable task ID

All generation tasks are asynchronous. HTTP/API success means that Kie.ai
accepted the task, not that generation completed.

## CLI Contract

```bash
# Discover the current catalog and exact per-model schemas
kie-helper.sh catalog

# Generic model submission: input is passed through unchanged
kie-helper.sh create --model nano-banana-2 \
  --params '{"prompt":"Editorial product photo","aspect_ratio":"16:9"}'

# Convenience commands merge prompt/text into model-specific JSON
kie-helper.sh image --model nano-banana-2 --prompt "Editorial product photo" \
  --params '{"resolution":"2K"}' --wait
kie-helper.sh video --model kling-3.0/video --prompt "Slow camera push-in" \
  --params '{"duration":"5","aspect_ratio":"16:9","mode":"pro","sound":true,"multi_shots":false,"multi_prompt":[]}'
kie-helper.sh audio --model elevenlabs/text-to-speech-turbo-2-5 \
  --text "Welcome" --params '{"voice":"Rachel"}'

# Recover or inspect asynchronous work
kie-helper.sh status TASK_ID
kie-helper.sh wait TASK_ID --timeout 900
kie-helper.sh credits

# Upload sources before passing their returned temporary URLs to a model
kie-helper.sh upload reference.png --path aidevops/references
kie-helper.sh upload-url https://example.com/reference.png --path aidevops/references
```

`create` prints the task ID. `wait` prints generated URLs or the returned
`resultObject`; add `--raw` to inspect the complete task record. Use
`--input-file` instead of `--params` for large or reusable JSON objects.

<!-- AI-CONTEXT-END -->

## Setup

Create a server-side API key at `https://kie.ai/api-key`, then store it without
putting the value in chat, shell history, source files, or client-side code:

```bash
aidevops secret set KIE_API_KEY
kie-helper.sh credits
```

The helper checks `KIE_API_KEY`, the protected aidevops credentials file, and
the `aidevops/KIE_API_KEY` gopass entry in that order.

## JSON-First Model Integration

Kie.ai standardizes task creation and status, not each model's `input` schema.
Always copy the exact model ID and fields from the current model page. Do not
translate parameter names from MuAPI, WaveSpeed, Runway, or another Kie model.

Representative, verified IDs are:

| Media | Model ID | Example fields |
|-------|----------|----------------|
| Image | `nano-banana-2` | `prompt`, `image_input`, `aspect_ratio`, `resolution`, `output_format` |
| Video | `kling-3.0/video` | `prompt`, `duration`, `aspect_ratio`, `mode`, `sound`, `multi_shots` |
| Audio | `elevenlabs/text-to-speech-turbo-2-5` | `text`, `voice`, `stability`, `speed` |

The catalog changes frequently. `kie-helper.sh catalog` deliberately points to
the live Market instead of pretending a local hard-coded list is complete.

## Task Results and Errors

The unified status response stores output as a JSON string in
`data.resultJson`:

- media commonly returns `{"resultUrls":[...]}`;
- some models add first/last-frame arrays;
- structured tools may return `{"resultObject":{...}}`.

On `fail`, preserve `taskId`, `failCode`, and `failMsg` for diagnosis. Treat API
codes `401`, `402`, `408`, `422`, `429`, `433`, `455`, `500`, `501`, and `505`
as failures, not task IDs. Check `https://kie.ai/logs` when credit use or
provider state is unclear.

## Uploads

The helper implements the documented stream and URL upload endpoints:

| Command | Endpoint | Required input |
|---------|----------|----------------|
| `upload` | `/api/file-stream-upload` | local file and upload path |
| `upload-url` | `/api/file-url-upload` | public HTTP(S) URL and upload path |

Upload and result-retention wording differs across Kie.ai documentation
surfaces. Treat every returned URL as temporary, download required assets
immediately, and persist the provider's expiry metadata when supplied.

## Callbacks and Security

For production, pass `--callback https://your-domain.com/api/callback` and
enable a webhook HMAC key in Kie.ai settings. Verify:

```text
base64(HMAC-SHA256(taskId + "." + X-Webhook-Timestamp, webhookHmacKey))
```

Use constant-time signature comparison and reject stale timestamps to prevent
forgery and replay. Never reuse `KIE_API_KEY` as the webhook HMAC key.

## Limits and Cost Safety

- Default generation limit documented by Kie.ai: 20 new tasks per 10 seconds
  per account. A rejected `429` task does not enter the queue.
- Polling is separate request traffic; callbacks are preferred at scale.
- Check `kie-helper.sh credits` and the current `https://kie.ai/pricing` page
  before a large batch.
- Never run a paid generation merely to test the helper. Use the deterministic
  fake-transport test in `.agents/scripts/tests/test-kie-helper.sh`.

## First-Party References

- [Kie.ai integration guide](https://docs.kie.ai/1973359m0.md)
- [Market overview](https://docs.kie.ai/market/quickstart.md)
- [Unified task details](https://docs.kie.ai/market/common/get-task-detail.md)
- [File upload API](https://docs.kie.ai/file-upload-api/quickstart.md)
- [Webhook verification](https://docs.kie.ai/common-api/webhook-verification.md)
- [Nano Banana 2](https://docs.kie.ai/market/google/nanobanana2.md)
- [Kling 3.0](https://docs.kie.ai/market/kling/kling-3-0.md)
- [ElevenLabs Turbo 2.5](https://docs.kie.ai/market/elevenlabs/text-to-speech-turbo-2-5.md)

## Related

- `content/media-generation-providers.md` - provider-selection source of truth
- `content/production-image.md` - image production workflow
- `content/production-video.md` - video production workflow
- `content/production-audio.md` - audio production workflow
- `content/video-muapi.md` - workflow-oriented multimodal gateway
- `content/video-wavespeed.md` - broad model gateway with model listing
- `content/video-runway.md` - direct Runway media pipeline
