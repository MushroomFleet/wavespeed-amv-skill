# WaveSpeed MiniMax H3 reference-to-video

Everything the scripts rely on. Read this when a submission behaves unexpectedly or a parameter
needs changing.

## Endpoints

```
POST  https://api.wavespeed.ai/api/v3/minimax/h3/reference-to-video
GET   https://api.wavespeed.ai/api/v3/predictions/{id}/result
```

Auth is `Authorization: Bearer <key>` on both. The API is asynchronous: submit, get an id back,
then poll the result endpoint.

**There is no upload endpoint.** `/api/v3/<anything>` routes as a model path, so a probe at
`/api/v3/media/upload` returns `400 {"code":400,"message":"Model not found."}` — which reads like
a malformed request to a real endpoint and is not. References must be publicly hosted first; see
`Publish-Refs.ps1`.

## Input

| Field | Type | Notes |
|---|---|---|
| `prompt` | string | **required** |
| `reference_images` | array of URL | at least one image or video is required |
| `reference_videos` | array of URL | up to 3, each normalised to 2–15s, combined cap 15s |
| `reference_audios` | array of URL | **cannot be supplied alone** — needs an image or video too |
| `aspect_ratio` | string | `21:9` `16:9` `4:3` `1:1` `3:4` `9:16`. Default `16:9` |
| `resolution` | string | `768p` or `2k`. Default `768p` — set it explicitly |
| `duration` | integer | 4–15 seconds. Default `5` |

All reference fields take **public HTTPS URLs**, never local paths or uploaded ids.

```json
{
  "prompt": "...",
  "aspect_ratio": "16:9",
  "resolution": "2k",
  "duration": 6,
  "reference_images": ["https://pub-xxxx.r2.dev/renders/shot01.png"],
  "reference_audios": ["https://pub-xxxx.r2.dev/audio/seg-01.wav"]
}
```

## Response

Both endpoints may wrap the payload in `data`. Handle either shape:

```
$task = if ($r.PSObject.Properties.Name -contains 'data') { $r.data } else { $r }
```

| Field | Notes |
|---|---|
| `id` | prediction id — the thing to log before polling |
| `status` | `created` `queued` `processing` → `completed` \| `failed` \| `cancelled` \| `timeout` \| `deleted` |
| `outputs` | array, empty until completed. Usually URL strings, sometimes objects with a `url` |
| `error`, `code` | present on failure |

Poll from ~2s and back off for longer tasks. Stop on any terminal status, not just `completed` —
`failed`, `cancelled`, `timeout` and `deleted` all end the job and will otherwise poll forever.

## What clips actually come back as

Measured on a 20-clip run at `2k` / `16:9` / `duration: 6`:

- **2560×1440, 24fps** — note this is 2560 wide, not 2720, so a seed image at a different size is
  resampled. Not a problem, but plan the cut around 2560×1440.
- **~6.58s, not 6.00s.** The duration parameter is a target, not a contract. Always trim to the
  length the timeline needs rather than assuming.
- **An audio track is present** when `reference_audios` was sent, carrying the supplied segment
  essentially unmodified — cross-correlation measured **0.97 at zero offset**. This is the useful
  part: the returned clip already holds its own music, so sync is verifiable by ear in the edit
  instead of trusted from arithmetic.
- Without `reference_audios`, the model invents ambience. Fine for a clip that will be retimed or
  silenced, wrong for anything that must sit on the beat.

## Cost

Billed per clip, not per second, at the tier the account is on. The run this skill was built from
charged **$0.84 per 6s 2k clip**. `Invoke-WaveSpeed.ps1 -CostPerClip` sets the figure used for
estimates and the `-MaxCost` guard — check the current rate rather than trusting the default.

## Mode matters more than it looks

Sending an audio reference puts the prompt in **full-reference** mode, which is a six-section
format (`subject_definitions`, `summary`, `retention_analysis`, `detailed_description`,
`overall_soundscape`, `non_diegetic_music`) — not the three-field image-to-video one. A prompt in
the wrong shape has nowhere to declare `<Audio 1>`, so the audio is silently discarded and the
clip returns with invented music at full price.

Use the `minimaxh3-enh` skill to write prompts; it routes modes correctly and knows the exact
field names.
