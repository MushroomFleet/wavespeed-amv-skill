---
name: wavespeed-amv-producer
description: End-to-end production of AMVs, music videos and any multi-clip video sequence on WaveSpeed's MiniMax H3 reference-to-video API — taking an IDEA through prompts, reference images, beat-timed audio segments, public hosting, a paid generation queue, and sequence-ordered delivery. Handles the part nobody else does: WaveSpeed accepts reference URLs but has no upload endpoint, so this stands up a private Cloudflare R2 CDN via the authenticated wrangler CLI to expose local stills and audio as public links. Use this whenever the user wants to generate a music video, AMV, animatic, trailer or any batch of clips cut to music; whenever they mention WaveSpeed, MiniMax H3, reference-to-video or r2v; whenever they have a song plus images and want clips cut to the beat; and whenever they need a render queue with polling, cost control, resumability and timeline-ordered filenames. Also use it for the pieces alone — splitting audio on measured bar lines, publishing local assets to an R2 public bucket for any API that needs URLs, or frame-locked trimming of delivered clips.
---

# WaveSpeed AMV Producer

Turn an IDEA plus a song into a finished set of clips that cut together on the beat.

The chain is: **measure the music → split it on bar lines → write one prompt per clip → get a seed
frame for each → publish references to your own CDN → queue the paid renders → trim to frame-exact
lengths.** Each stage writes a file the next stage reads, so any stage can be re-run alone and the
whole thing is resumable.

## Why this skill exists

Three things make this harder than "call an API in a loop", and all three are solved here:

1. **WaveSpeed has no upload endpoint.** `reference_images` and `reference_audios` take public
   HTTPS URLs. Local files cannot be used. `scripts/Publish-Refs.ps1` stands up an R2 bucket with
   a public dev URL and mirrors your assets to it — free at this scale, with no egress cost, which
   matters because the API refetches on every render and every re-roll.
2. **Renders cost real money and are not refundable.** Every guard in `Invoke-WaveSpeed.ps1`
   exists because of a specific way money gets wasted. Read *Money discipline* below before
   running it.
3. **Cutting to music is a frame problem, not a duration problem.** A bar at most tempos is not a
   whole number of frames. `scripts/Trim-Clips.ps1` derives each clip's length from its position
   on the timeline rather than a fixed duration, which is the difference between sub-frame
   accuracy and a third of a second of drift.

## Setup, once per machine

| Requirement | Check | Notes |
|---|---|---|
| `pwsh` 7+ | `$PSVersionTable.PSVersion` | Windows PowerShell 5.1 will not run these |
| `python` 3.10+ with numpy, scipy | `python -c "import numpy, scipy"` | tempo analysis only |
| `ffmpeg` | `ffmpeg -version` | audio decode, splitting, trimming |
| `wrangler`, authenticated | `wrangler whoami` | `wrangler login` if not |
| WaveSpeed API key | see below | |
| `higgsfield`, authenticated | `higgsfield account status` | **optional**, only for generating stills |

### The API key

This skill does not store credentials for you. It looks in two places, in order:

1. **`$env:WAVESPEED_API_KEY`** — the variable WaveSpeed's own documentation uses. Preferred,
   because following the vendor's convention is not inventing a credential pattern.
2. **A key file** (`.wavespeed_key` by default) — a convenience for an interactive project. Copy
   `assets/wavespeed_key.template` into the project root and replace the placeholder.

With neither, the scripts stop and say exactly what to set rather than guessing. The value is used
in an `Authorization` header and is never written to disk, logged or echoed. If you use the file
and the project is in git, add it to `.gitignore` before pasting the key in.

### Conventions the scripts follow

Logic lives in functions; each script's top level is a thin call into `Invoke-Main`, so pieces can
be dot-sourced and tested alone. Human progress goes to the **host** via `Write-Human`, while the
**pipeline carries objects** — `$r = ./Invoke-WaveSpeed.ps1` gives typed results, not a
transcript. Shared helpers live in `scripts/_Common.ps1`.

TINA (`Invoke-TINAProcess`) is used for process capture when present, so runs land in its log; the
scripts fall back to direct invocation when it is not installed, and work either way.

## The chain

Work in the user's project directory, not in the skill directory. Every script takes
`-ProjectRoot` (PowerShell) or a path argument (Python) and defaults to the current directory.

### 0 — Scaffold the project

```powershell
pwsh -File <skill>/scripts/New-Project.ps1 -Name <track-name>
cd <track-name>
```

Creates `audio/ renders/ prompts/stills/ video/raw/ video/cut/`, a `PROJECT.md` to fill in, and a
`.gitignore`.

**That `.gitignore` is the OPSEC step, not housekeeping.** Step 6 rewrites `clips.json` with the
public R2 URLs of every seed frame and audio segment, and saves the same map to `refs-r2.json`.
Both files land in the user's project. Committing either publishes their bucket address, and that
bucket is public and unauthenticated while a run is live — anyone reading the repo could fetch
every reference they uploaded. If a user skips this scaffold, check they have those two files
ignored before they ever run `Publish-Refs.ps1`.

### 1 — Measure the music

```bash
python <skill>/scripts/analyze_tempo.py <track.mp3> --out tempo.json
```

Writes BPM, beat and bar length, and the downbeat grid. It also reports a **confidence figure** —
how much more onset energy sits on grid beats than off them. Below about 3σ, do not trust the grid;
tell the user and ask for the tempo rather than silently building a timeline on a bad measurement.

Ask the user where the sequence should start. For a music video this is usually a drop or a first
downbeat, and `--find-drop` will locate the largest energy jump for them to confirm. **Measure it;
do not accept a round number.** A user saying "the drop is at 38 seconds" is telling you roughly
where to look, not giving you a cut point — on the project this skill was built from, the real
downbeat was 38.9409s and 38.0s landed in a silent gap.

### 2 — Split the audio on bar lines

```bash
python <skill>/scripts/split_audio.py <track.mp3> --tempo tempo.json \
    --start 38.9409 --bars 3 --out audio/ --prefix seg
```

Cuts contiguous, sample-exact segments of N bars each. Contiguity is what matters: each segment
begins exactly where the previous ended, so the segments reassemble into the original track with
no gap and no click, and the clip boundaries land on downbeats.

Choose `--bars` from the clip length the model supports and the tempo. At 125 BPM, 3 bars is
5.77s, which fits a 6-second render with a little to trim. `--report` prints the options.

### 3 — Write one prompt per clip

Prompts are ordinary markdown documents containing fenced ` ```text ` blocks, one per clip, in
sequence order. **Use the `minimaxh3-enh` skill to write them** — it knows the exact field names
and mode routing this model expects, and a prompt in the wrong shape wastes a paid render.

Feeding an audio segment to a clip puts it in **full-reference** mode, which is a six-section
format, not the three-field image-to-video one. Getting this wrong means the audio is silently
discarded and the clip comes back with invented music.

The thing that makes motion land on the beat: **write rhythmic action as a countable number of
visible events**, because a model cannot act on "on the beat". "Twelve evenly spaced strikes
across the first 5.77 seconds, alternating palm then fist" is executable. "Drums in time with the
music" is not.

### 4 — Seed frames

Every clip needs one reference image. Either the user supplies them, or generate them:

```powershell
pwsh -File <skill>/scripts/New-Stills.ps1 -PromptDir prompts/stills -OutDir renders -Only L1 -DryRun
pwsh -File <skill>/scripts/New-Stills.ps1 -PromptDir prompts/stills -OutDir renders
```

Each `.txt` in `-PromptDir` is one still. `-ReferenceImage` accepts up to 10 donors — pass a
character sheet when a person or creature must stay consistent across shots. Leave it off for
landscapes, where a strong reference makes every frame converge on the same composition.

### 5 — Build the queue

```bash
python <skill>/scripts/build_clips.py --prompts prompts.md --images renders --audio audio --out clips.json
```

Pairs prompt blocks with images and audio segments in order, assigns sequence-ordered output
filenames, and computes each clip's timeline position. **Show the user the table it prints and get
it confirmed before spending anything** — a mispairing here means every clip after it is wrong.

### 6 — Publish references

```powershell
pwsh -File <skill>/scripts/Publish-Refs.ps1 -Bucket <name>
```

Creates the bucket if needed, enables its public dev URL, uploads every asset `clips.json`
references with correct MIME types, verifies each returns HTTP 200, and rewrites `clips.json` with
the public URLs. Idempotent — an object already present at the same size is skipped.

**Two things to tell the user, both concrete.**

The bucket is public and unauthenticated. Anyone holding a URL can fetch the assets. The hostname
hash is unguessable, so there is no discovery path, but it is their material and their call.
`-Teardown` disables the public URL again — at the cost of breaking re-rolls until it is
re-enabled, so it suits unreleased work rather than being a default.

`clips.json` and `refs-r2.json` now contain that bucket URL. If the project is in git, confirm
both are ignored. `New-Project.ps1` does this; a hand-made project may not.

### 7 — Generate

```powershell
pwsh -File <skill>/scripts/Invoke-WaveSpeed.ps1 -Only 1 -DryRun
pwsh -File <skill>/scripts/Invoke-WaveSpeed.ps1 -Only 1        # prove it on ONE clip
pwsh -File <skill>/scripts/Invoke-WaveSpeed.ps1                # then the rest
```

Always render one clip and check it before queueing the batch. Verify: the resolution is what you
asked for, the first frame matches the seed image, and — if you sent audio — that the returned
clip carries *your* audio rather than something invented. `scripts/check_clip.py` measures that
last one by cross-correlation; above ~0.5 means your segment was reused.

### 8 — Trim to the timeline

```powershell
pwsh -File <skill>/scripts/Trim-Clips.ps1 -DryRun
pwsh -File <skill>/scripts/Trim-Clips.ps1
```

Cuts each clip's tail to `round(out × fps) − round(in × fps)`. Originals are never modified;
copies go to a new folder under identical filenames, so a human editor can still reach for a
clip's later seconds in the final cut.

`scripts/Retime-Clip.ps1` handles the case where one clip must *stretch* to cover a long tail
rather than be trimmed — an outro, usually.

## Money discipline

These are not style preferences. Each one is a way money was actually wasted.

- **Never retry a submission.** A retry re-charges for an identical job. Submission happens once;
  only the status poll is allowed to be patient. If a submission fails, surface it and let the
  user decide.
- **Log the prediction id before polling.** A crash or a dropped connection after submission
  otherwise loses all trace of a job that was already paid for.
- **Render one clip first, always.** The batch is only worth queueing once one clip has been
  eyeballed.
- **Verify parameters landed before waiting on the job.** Check the submitted job actually has the
  aspect ratio and prompt you sent. A silently coerced parameter produces a useless render at
  full price.
- **Skip work already delivered.** A clip whose output file exists is not re-rendered, which makes
  an interrupted run resumable by simply running it again.
- **`-MaxCost` refuses to start** above a spend ceiling. Tell the user the total before running
  and let them set it.

## Reference files

- `references/wavespeed-api.md` — endpoint, parameters, polling, response shapes, error handling
- `references/beat-timing.md` — how the tempo measurement works, why boundaries are rounded rather
  than durations, and how to pick a bar count
- `references/traps.md` — the CLI and ffmpeg failure modes that cost money or produce silently
  wrong output. Read this before debugging anything odd.

## When a stage misbehaves

Check `references/traps.md` first — most surprises here are known. The ones that bite hardest:
a CLI argument containing newlines can be silently truncated *and* displace later flags; a space
in a file path can break a signed upload; and `ffmpeg -c copy -t` is not frame-accurate, so a trim
that trusts it produces wrong lengths without erroring.
