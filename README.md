# wavespeed-amv-producer

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

**Produce a complete music video, end to end, from a song and a set of prompts.**

A Claude Code skill that drives [WaveSpeed's](https://wavespeed.ai) **MiniMax H3
reference-to-video** model at 2K, using *sliced music* as a reference input so the generated
motion is driven by the track itself rather than described at it.

### See it working

**▶ [Example music video](https://www.youtube.com/watch?v=JcRWaZipTDk)** — 2 minutes, 20 clips at
2560×1440, generated fully automatically from a song, a set of still frames and a prompt
document, for **under $15** of API spend.

Per-clip pricing depends on your tier, length and resolution, so check your own rate and set
`-MaxCost` accordingly.

---

## The idea

Most image-to-video work describes motion in words and hopes it lands on the beat. This does
something different: **the track is cut into bar-length segments, and each segment is fed to the
model as an audio reference alongside its seed frame.** The clip comes back already carrying its
own slice of the music.

That has two consequences that matter more than they sound:

- **The model animates to audio it can actually hear.** Motion written as countable events —
  "twelve evenly spaced strikes across 5.77 seconds" — lands against a real rhythm rather than a
  description of one.
- **Assembly becomes verifiable by ear.** Every delivered clip contains its own music, so laying
  them end to end either sounds right or doesn't. You are not trusting arithmetic.

Because the segments are cut on measured bar lines and are contiguous to the sample, the clips
butt-join back into the original track with no gap and every cut landing on a downbeat.

## The chain

Each stage writes a file the next one reads, so any stage re-runs alone and the whole thing is
resumable.

```
  New-Project.ps1      scaffold folders + a .gitignore that protects you  →  <project>/
  analyze_tempo.py     measure BPM, bar length and the downbeat grid  →  tempo.json
  split_audio.py       cut contiguous N-bar segments on that grid     →  audio/, segments.json
  (your prompts)       one per clip, as ```text blocks in markdown
  New-Stills.ps1       optional — generate seed frames                →  renders/
  build_clips.py       pair prompts + frames + segments, in order     →  clips.json
  Publish-Refs.ps1     mirror references to your own R2 bucket        →  public URLs
  Invoke-WaveSpeed.ps1 submit, poll, download, name in sequence order →  video/raw/
  Trim-Clips.ps1       cut frame-exact to the timeline                →  video/cut/
```

Output filenames are sequence-ordered (`001-…`, `002-…`), so sorting by name gives timeline
order in any NLE.

## Requirements

| | |
|---|---|
| **WaveSpeed account** | the model this drives — [wavespeed.ai](https://wavespeed.ai) |
| **Cloudflare account** | **required** — see below |
| `pwsh` 7+ | Windows PowerShell 5.1 will not run these |
| `python` 3.10+ with `numpy`, `scipy` | tempo analysis |
| `ffmpeg` on PATH | audio decode, splitting, trimming |
| `wrangler`, authenticated | `wrangler login` |
| `higgsfield` | **optional** — only if you want the skill to generate seed frames too |

### Why Cloudflare is not optional

WaveSpeed's `reference_images` and `reference_audios` fields take **public HTTPS URLs**, and the
service has no upload endpoint of its own. Local files simply cannot be used. Your seed frames
and audio segments have to be hosted somewhere reachable before a render can consume them.

`Publish-Refs.ps1` solves this by standing up a **Cloudflare R2 bucket** with a public dev URL and
mirroring your assets into it. R2 suits the job better than a general object store for one
specific reason: **no egress charges**. The API refetches every reference on every render and
every re-roll, and a normal project sits inside the free tier comfortably.

A free Cloudflare account is enough. The script creates the bucket, enables public access,
uploads with correct MIME types, verifies every URL serves, and rewrites your queue with the
public links. `-Teardown` disables public access again when the run is done.

### Keep your bucket URL out of git

`Publish-Refs.ps1` rewrites `clips.json` with the public URL of every seed frame and audio
segment, and saves the same map to `refs-r2.json`. **Both files live in your project.** Commit
either one and your bucket address is published — and that bucket is public and unauthenticated
while a run is live, so anyone reading the repo could fetch every reference you uploaded.

`New-Project.ps1` writes a `.gitignore` that covers both, along with your API key. If you build a
project by hand instead, add them yourself before you ever run `Publish-Refs.ps1`:

```gitignore
.wavespeed_key
clips.json
refs-r2.json
```

`-Teardown` disables the bucket's public URL when you are done. It breaks re-rolls until you
re-enable it, so it suits unreleased material rather than being a default.

## The API key

No credential store is invented for you. Two places are checked, in order:

```powershell
$env:WAVESPEED_API_KEY = '<your key>'   # preferred — WaveSpeed's own documented variable
```

…or a key file (`.wavespeed_key`) — copy `<skill>/assets/wavespeed_key.template` and replace the
placeholder. It is already in `.gitignore`. With neither set, the scripts stop and tell you what
to do rather than guessing.

## Install

The skill lives in the `wavespeed-amv-producer/` folder. Copy that folder into a Claude Code
skills directory and it is picked up on the next session:

```bash
git clone https://github.com/MushroomFleet/wavespeed-amv-skill
cp -r wavespeed-amv-skill/wavespeed-amv-producer ~/.claude/skills/        # every project
# or
cp -r wavespeed-amv-skill/wavespeed-amv-producer <project>/.claude/skills/ # one project
```

The scripts are plain `pwsh` and `python` and run without Claude Code too. Below, `<skill>` means
wherever that folder ended up.

## Quick start

```bash
pwsh -File <skill>/scripts/New-Project.ps1 -Name my-track   # scaffold + .gitignore. do this first
cd my-track

python <skill>/scripts/analyze_tempo.py track.mp3 --find-drop
python <skill>/scripts/split_audio.py   track.mp3 --tempo tempo.json --start <drop> --bars 3 --out audio/

# write one prompt per clip into prompts.md as ```text blocks, in sequence order

python <skill>/scripts/build_clips.py   --prompts prompts.md --images renders --audio audio
pwsh -File <skill>/scripts/Publish-Refs.ps1     -Bucket my-refs

pwsh -File <skill>/scripts/Invoke-WaveSpeed.ps1 -Only 1          # ONE clip first, always
python <skill>/scripts/check_clip.py video/raw/001-*.mp4 --audio audio/seg-01.wav

pwsh -File <skill>/scripts/Invoke-WaveSpeed.ps1                  # then the batch
pwsh -File <skill>/scripts/Trim-Clips.ps1
```

[`USER-GUIDE.md`](USER-GUIDE.md) walks every stage with flags, files in, files out and the check to
run before moving on. `wavespeed-amv-producer/SKILL.md` carries the reasoning behind each stage.

## Choosing a clip length

`split_audio.py --report` prints which bar counts fit which render lengths at your tempo. The
model supports **4–15 second** clips, so the segment length and the render length are chosen
together:

```
 bars    segment   fits in
    2    3.8452s        4s
    3    5.7678s        6s
    4    7.6903s        8s
```

At 125 BPM, three bars is 5.77s into a 6-second render. At phonk tempos the arithmetic lands
differently — run the report rather than assuming.

## Money discipline

Renders are paid and non-refundable, and every guard here exists because of a specific way money
got wasted:

- **Submission is never retried.** A retry re-charges for an identical job. Only the poll is
  allowed to be patient.
- **The prediction id is logged before polling starts**, so a crash or dropped connection after
  submission still leaves a record of what was bought.
- **Delivered clips are skipped**, so an interrupted run resumes by simply running it again.
- **`-MaxCost` refuses to start** above a spend ceiling you set.
- **Render one clip and look at it** before queueing a batch. `check_clip.py` verifies the
  resolution landed and — by cross-correlation — that the returned clip carries *your* audio
  rather than something the model invented.

## Cutting to music is a frame problem

A musical bar is rarely a whole number of frames. At 125 BPM and 24fps, three bars is **138.43
frames**.

Rounding each clip's *length* gives a flat 138 every time, losing 0.018s per clip — about a third
of a second of drift over twenty clips, with the picture running ahead of the track. Rounding
each timeline *boundary* instead gives lengths that alternate 138/139 and holds total error under
half a frame.

`Trim-Clips.ps1` does the latter. Originals are never modified; cuts go to a new folder under
identical filenames, so an editor can still reach for a clip's later seconds.

## What's in the box

```
wavespeed-amv-producer/
  SKILL.md                     the chain, and why each stage works the way it does
  scripts/                     10 scripts + _Common.ps1 shared helpers
  references/wavespeed-api.md  endpoint, parameters, response shapes, what clips come back as
  references/beat-timing.md    how tempo is measured; why boundaries are rounded, not durations
  references/traps.md          failure modes that produce silently wrong output or wasted money
  assets/                      API key template
USER-GUIDE.md                  prerequisites and step-by-step operation, for agents and people
LICENSE, NOTICE                Apache 2.0
```

**Read `wavespeed-amv-producer/references/traps.md` before debugging anything odd.** It documents the failures that
don't announce themselves — a CLI argument containing newlines being truncated *and* displacing
later flags, a space in a file path breaking a signed upload, `ffmpeg -c copy -t` not being
frame-accurate, and the difference between rounding durations and rounding boundaries.

## Conventions

Logic lives in functions; each script's top level is a thin `Invoke-Main` call, so pieces can be
dot-sourced and tested alone. Human progress goes to the host while **the pipeline carries
objects** — `$r = ./Invoke-WaveSpeed.ps1` returns typed results, not a transcript.

[TINA](https://github.com/MushroomFleet/tina-public) is used for process capture when it is loaded,
so runs land in its log. The scripts fall back to direct invocation when it is absent and work
either way — TINA is **not** required.

## Status

Proven end to end on a real production — the video linked above. Every downstream number
(tempo, segment boundaries, frame plan, audio correlation) was reproduced independently by these
scripts afterwards.

Not yet put through a formal trigger/behaviour evaluation. Treat it as working and useful rather
than hardened, and read `traps.md` before assuming a surprise is your fault.

### Known gap: video references

The H3 API also accepts **`reference_videos`** — up to 3 clips, each normalised to 2–15s, with a
combined cap of 15s. These scripts do not expose it yet. The plumbing is small; knowing what
belongs in those slots is the interesting part, and that research is ongoing.

## Licence

Apache License 2.0 — see [`LICENSE`](LICENSE).

---

## 📚 Citation

### Academic Citation

If you use this codebase in your research or project, please cite:

```bibtex
@software{wavespeed_amv_producer,
  title = {wavespeed-amv-producer: Beat-Synchronised Music Video Production for MiniMax H3 Reference-to-Video},
  author = {Drift Johnson},
  year = {2026},
  url = {https://github.com/MushroomFleet/wavespeed-amv-skill},
  version = {1.0.0}
}
```

### Donate:

[![Ko-Fi](https://cdn.ko-fi.com/cdn/kofi3.png?v=3)](https://ko-fi.com/driftjohnson)
