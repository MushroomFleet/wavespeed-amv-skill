# USER GUIDE — wavespeed-amv-producer

This guide is written so that an agent or a person can set the system up from nothing and run it
end to end without reading the source. Every stage lists the command, the flags that matter, the
file it reads, the file it writes, and how to confirm it worked before moving on.

The README explains *why* the chain is shaped this way. This document explains *how to run it*.

---

## 1. What this does

Input: one song, one seed image per clip, one text prompt per clip.
Output: a set of video clips, each carrying its own slice of the music, cut on bar lines, named in
timeline order, trimmed frame-exact, ready to drop onto an editor's timeline.

Renders are made by WaveSpeed's **MiniMax H3 reference-to-video** model. Every render is paid and
non-refundable, so the chain is built to prove one clip before spending on twenty.

---

## 2. Prerequisites

### 2.1 Accounts

| Account | Purpose | Required |
|---|---|---|
| [WaveSpeed](https://wavespeed.ai) | the video model, billed per clip | **yes** |
| [Cloudflare](https://dash.cloudflare.com) | R2 bucket to host references as public URLs | **yes** — free tier is enough |
| [Higgsfield](https://higgsfield.ai) | generating seed frames, only if you do not already have them | optional |

Cloudflare is not optional. WaveSpeed accepts reference images and audio **only as public HTTPS
URLs** and has no upload endpoint. Something has to host the files, and `Publish-Refs.ps1` uses R2
because it has no egress charges and the API refetches every reference on every render.

### 2.2 Tools

| Tool | Minimum | Verify with | Install |
|---|---|---|---|
| `pwsh` | 7.0 | `pwsh -Command '$PSVersionTable.PSVersion'` | https://github.com/PowerShell/PowerShell |
| `python` | 3.10 | `python --version` | https://python.org |
| `numpy`, `scipy` | any current | `python -c "import numpy, scipy"` | `pip install numpy scipy` |
| `ffmpeg` | any current, on PATH | `ffmpeg -version` | https://ffmpeg.org/download.html |
| `wrangler` | 3.x+, logged in | `wrangler whoami` | `npm i -g wrangler` then `wrangler login` |
| `higgsfield` CLI | logged in | `higgsfield account status` | optional, only for `New-Stills.ps1` |

**Windows PowerShell 5.1 will not run these scripts.** The command is `pwsh`, not `powershell`.
Every PowerShell example below is invoked as `pwsh -File <script> <args>`.

`ffmpeg` must be on PATH or passed explicitly: `--ffmpeg <path>` for the Python scripts,
`-FfmpegPath <path>` for the PowerShell scripts. The scripts will not guess a location.

### 2.3 Optional: TINA

If the [TINA](https://github.com/MushroomFleet/tina-public) module is loaded in the session, the
PowerShell scripts route external CLI calls through it so runs land in TINA's log. If it is not
loaded, they call the CLIs directly. Nothing here requires TINA.

---

## 3. Install

The skill is the `wavespeed-amv-producer/` folder. Everything else in this repository is
licensing and documentation.

```bash
git clone https://github.com/MushroomFleet/wavespeed-amv-skill
```

**As a Claude Code skill** — copy the folder into a skills directory. It is picked up on the next
session and triggers on requests to make a music video, AMV, or beat-cut clip sequence:

```bash
cp -r wavespeed-amv-skill/wavespeed-amv-producer ~/.claude/skills/            # all projects
cp -r wavespeed-amv-skill/wavespeed-amv-producer <project>/.claude/skills/     # one project
```

**As standalone scripts** — leave the folder anywhere and call the scripts by path.

In this guide `<skill>` means the absolute path of the `wavespeed-amv-producer` folder, wherever
it ended up. All commands are run from inside **your project folder**, never from inside the skill.

---

## 4. Credentials

### 4.1 WaveSpeed API key

The scripts look in two places, in this order, and stop with an explicit message if neither is set:

1. Environment variable `WAVESPEED_API_KEY` — **preferred**. This is the variable WaveSpeed's own
   documentation uses.

   ```powershell
   $env:WAVESPEED_API_KEY = '<your key>'
   ```

2. A file named `.wavespeed_key` in the project root containing the key and nothing else. Create
   it by copying the template:

   ```bash
   cp <skill>/assets/wavespeed_key.template .wavespeed_key
   # then replace the placeholder line with the key
   ```

The key goes into an `Authorization: Bearer` header and is never written to disk, logged, or
echoed. If the file still holds the placeholder text, the scripts refuse to run.

### 4.2 Cloudflare

`wrangler login` once. `Publish-Refs.ps1` checks `wrangler whoami` before doing anything and stops
if it fails.

### 4.3 Higgsfield (optional)

`higgsfield auth login` once. `New-Stills.ps1` checks `higgsfield account status` first.

### 4.4 What must never be committed

If your project folder is a git repository, these files must be ignored **before** the stages that
write them run:

```gitignore
.wavespeed_key      # your API key
clips.json          # rewritten with your live public bucket URLs by Publish-Refs.ps1
refs-r2.json        # the same URL map
```

`New-Project.ps1` writes a `.gitignore` that covers all three. If you build a project folder by
hand, add them yourself.

---

## 5. Project layout

Every script takes `-ProjectRoot <path>` (PowerShell) or resolves paths relative to the current
directory (Python). Default is the current directory. Work inside the project, not inside the skill.

```
<project>/
  track.mp3              your song (any name, any ffmpeg-readable format)
  PROJECT.md             notes; written by New-Project.ps1, fill in as you go
  .gitignore             written by New-Project.ps1
  prompts.md             YOUR prompts, one ```text block per clip, in order
  prompts/stills/        optional: one .txt per seed frame for New-Stills.ps1
  renders/               seed frames, one per clip, sorted order = clip order
  tempo.json             ← analyze_tempo.py
  audio/                 ← split_audio.py (seg-01.wav, seg-02.wav, …, segments.json)
  clips.json             ← build_clips.py, rewritten by Publish-Refs.ps1
  refs-r2.json           ← Publish-Refs.ps1
  wavespeed-log.jsonl    ← Invoke-WaveSpeed.ps1, one line per paid submission
  video/raw/             ← Invoke-WaveSpeed.ps1 (001-c01-slug.mp4, …)
  video/cut/             ← Trim-Clips.ps1 (same filenames, trimmed)
```

Each stage writes a file the next stage reads. Any stage can be re-run alone. Every stage that
spends money skips work already delivered, so an interrupted run resumes by running it again.

---

## 6. The chain, step by step

Order is fixed. Do not skip the verification lines.

### Step 0 — Scaffold the project

```bash
pwsh -File <skill>/scripts/New-Project.ps1 -Name my-track
cd my-track
```

| Flag | Default | Meaning |
|---|---|---|
| `-Name` | required | folder to create |
| `-Path` | `.` | where to create it |
| `-Force` | off | scaffold into an existing folder |

Writes: `audio/ renders/ prompts/stills/ video/raw/ video/cut/`, `PROJECT.md`, `.gitignore`.

Then put your track in the folder and set the API key (section 4.1).

### Step 1 — Measure the music

```bash
python <skill>/scripts/analyze_tempo.py track.mp3 --find-drop
```

| Flag | Default | Meaning |
|---|---|---|
| `track` | required | audio file |
| `--out` | `tempo.json` | output file |
| `--find-drop` | off | report the largest energy jump, snapped to the grid, as a candidate start point |
| `--anchor <sec>` | none | a known downbeat; locks the bar grid through it instead of guessing phase from accents. **Prefer this when you have one** |
| `--from <sec>` `--to <sec>` | whole track | analyse a section only |
| `--min-bpm` `--max-bpm` | 60 / 200 | search range |
| `--beats-per-bar` | 4 | time signature numerator |
| `--ffmpeg` | PATH | explicit ffmpeg path |

Writes `tempo.json`:

```json
{ "track": "track.mp3", "duration": 183.4, "bpm": 124.832, "beat": 0.48065,
  "beats_per_bar": 4, "bar": 1.92258, "first_downbeat": 0.31,
  "lock_strength": 0.61, "grid_sigma": 7.4, "anchored": false }
```

**Verify before continuing:**

- `grid_sigma` comfortably above **3**. Below that, the grid is not trustworthy. Ask a human for
  the tempo, or re-run with `--from/--to` on a section with clear drums, or `--anchor` a known
  downbeat.
- Confirm the start point with a human. `--find-drop` proposes; a person decides. **Do not accept a
  round number** such as "38 seconds". Measured downbeats are things like `38.9409`. A round guess
  lands in the wrong place and every cut downstream inherits the error.

### Step 2 — Choose a clip length

```bash
python <skill>/scripts/split_audio.py track.mp3 --tempo tempo.json --report
```

Prints, for each bar count, the segment length and which render length it fits inside:

```
 bars    segment   fits in
    2    3.8452s        4s
    3    5.7678s        6s
    4    7.6903s        8s
```

The model renders **4 to 15 seconds**. Pick a bar count whose segment fits inside a supported
render length with a little slack to trim. At most dance tempos, **3 bars into a 6-second render**
is the default. Fewer clips cost less; each clip must hold attention longer.

### Step 3 — Split the audio

```bash
python <skill>/scripts/split_audio.py track.mp3 --tempo tempo.json --start 38.9409 --bars 3 --out audio/
```

| Flag | Default | Meaning |
|---|---|---|
| `track` | required | audio file |
| `--tempo` | `tempo.json` | from step 1 |
| `--bars` | 3 | bars per segment |
| `--start <sec>` | none | split point. Segments before it are a separately numbered lead-in; segments from it are the main run. Omit to segment the whole track as one run |
| `--out` | `audio` | output folder |
| `--prefix` | `seg` | filename prefix for main segments |
| `--lead-prefix` | `<prefix>-intro` | prefix for lead-in segments |
| `--tail-mode` | `separate` | what to do with the remainder at the end: `separate` (own file), `absorb` (into the last segment), `drop` |
| `--ffmpeg` | PATH | explicit ffmpeg path |

Writes `audio/seg-01.wav …` and `audio/segments.json`:

```json
{ "track": "track.mp3", "sample_rate": 44100, "bar": 1.92258, "bars_per_segment": 3,
  "segments": [ { "file": "audio/seg-01.wav", "index": 1, "group": "seg",
                  "start": 38.9409, "end": 44.70874, "seconds": 5.76784, "frames": 254369 }, … ] }
```

Boundaries are sample-exact. `--audio` in step 6 points at this folder.

**Verify:** the printed table ends with a contiguity check that must read `True`. Each segment
starts exactly where the previous one ended, so they reassemble into the original with no gap.

### Step 4 — Write one prompt per clip

Prompts live in a markdown file as fenced ` ```text ` blocks, **one block per clip, in sequence
order**. Nothing else in the file is read. A heading before each block becomes part of the output
filename slug.

````markdown
## Clip 01 — the hall

```text
<full prompt for clip 1>
```

## Clip 02 — the street

```text
<full prompt for clip 2>
```
````

Two rules that decide whether the paid render is usable:

1. **Use full-reference format when audio is attached.** Sending `reference_audios` puts the model
   in full-reference mode, which expects six sections: `subject_definitions`, `summary`,
   `retention_analysis`, `detailed_description`, `overall_soundscape`, `non_diegetic_music`. A
   three-field image-to-video prompt has nowhere to declare `<Audio 1>`, so the audio is silently
   discarded and the clip comes back with invented music at full price. The `minimaxh3-enh` skill
   writes prompts in the right shape.
2. **Write rhythm as countable events.** "Twelve evenly spaced strikes across the first 5.77
   seconds" is executable. "Drums in time with the music" is not.

### Step 5 — Seed frames

One image per clip, in `renders/`, whose **sorted filename order is the clip order**. Either supply
them, or generate them from one `.txt` prompt per still in `prompts/stills/`:

```bash
pwsh -File <skill>/scripts/New-Stills.ps1 -PromptDir prompts/stills -OutDir renders -DryRun
pwsh -File <skill>/scripts/New-Stills.ps1 -PromptDir prompts/stills -OutDir renders
```

| Flag | Default | Meaning |
|---|---|---|
| `-PromptDir` | `prompts/stills` | one `.txt` per still, generated in sorted order |
| `-OutDir` | `renders` | output, same basename as the `.txt`, `.png` |
| `-Only a,b` | all | basenames or prefixes to render |
| `-ReferenceImage a,b` | none | up to 10 donor images. Pass a character sheet when a subject must stay consistent. Leave off for landscapes |
| `-Model` | `seedream_v5_pro` | Higgsfield model id |
| `-Resolution` | `2k` | |
| `-AspectRatio` | `16:9` | must match the video aspect ratio |
| `-DryRun` | off | list what would be submitted, spend nothing |

Stills already present in `-OutDir` are skipped. Submissions are never retried. Multi-line prompt
files are collapsed to one line before submission, because the Higgsfield CLI truncates on
newlines (see `references/traps.md`).

### Step 6 — Build the queue

```bash
python <skill>/scripts/build_clips.py --prompts prompts.md --images renders --audio audio
```

| Flag | Default | Meaning |
|---|---|---|
| `--prompts` | required | markdown file(s), comma separated, in order |
| `--images` | required | directories and/or files, comma separated, in order |
| `--audio` | none | folder holding `segments.json`. Omit for no audio |
| `--out` | `clips.json` | |
| `--duration` | 6 | render seconds requested from the model (4–15) |
| `--resolution` | `2k` | `768p` or `2k` |
| `--aspect-ratio` | `16:9` | `21:9` `16:9` `4:3` `1:1` `3:4` `9:16` |
| `--no-audio-for` | none | 1-based clip indexes to leave without audio (e.g. an outro to be retimed) |
| `--outdir-name` | none | prefix inside output filenames |

Writes `clips.json`, an array of:

```json
{ "seq": 1, "id": "C01", "slug": "the-hall", "prompt": "…",
  "image": "renders/01.png", "audio": "audio/seg-01.wav",
  "timeline_in": 38.9409, "timeline_out": 44.7087, "cut": 5.7678,
  "duration": 6, "resolution": "2k", "aspect_ratio": "16:9",
  "out": "001-c01-the-hall.mp4" }
```

**Verify:** the script prints a pairing table (seq, id, image, audio, in, out, cut). **Show it to
a human and get it confirmed before spending anything.** One row out of order shifts every clip
after it, and that only becomes visible after paying for all of them. Counts of prompts, images and
segments should match; mismatches are printed as notes.

### Step 7 — Publish references

```bash
pwsh -File <skill>/scripts/Publish-Refs.ps1 -Bucket my-amv-refs
```

| Flag | Default | Meaning |
|---|---|---|
| `-Bucket` | required | R2 bucket name; created if missing |
| `-ClipsFile` | `clips.json` | |
| `-Prefix` | none | key prefix inside the bucket |
| `-Force` | off | re-upload even if an object of the same size is already there |
| `-Teardown` | off | disable the bucket's public URL and exit. Objects are kept |

What it does, in order: verifies `wrangler` is authenticated → creates the bucket if needed →
enables its public dev URL (`https://pub-<hash>.r2.dev`) → uploads every local `image` and `audio`
path in `clips.json` with the correct MIME type → HEAD-checks every URL returns 200 → rewrites
`clips.json` with the public URLs → saves the local→URL map to `refs-r2.json`.

**Two things to tell the user, every time:**

- The bucket is **public and unauthenticated** while enabled. The hostname hash is unguessable, so
  there is no discovery path, but anyone holding a URL can fetch the assets. Run `-Teardown` when
  the render queue is finished if the material is unreleased. Teardown breaks re-rolls until
  re-enabled.
- `clips.json` and `refs-r2.json` now contain the bucket URL. Confirm both are git-ignored.

Re-running is idempotent: objects already present at the same size are skipped.

### Step 8 — Render one clip, then the batch

```bash
pwsh -File <skill>/scripts/Invoke-WaveSpeed.ps1 -Only 1 -DryRun     # shows exactly what would be sent
pwsh -File <skill>/scripts/Invoke-WaveSpeed.ps1 -Only 1             # ONE paid clip
python <skill>/scripts/check_clip.py video/raw/001-*.mp4 --audio audio/seg-01.wav --expect-dims 2560x1440
pwsh -File <skill>/scripts/Invoke-WaveSpeed.ps1                     # the rest
```

| Flag | Default | Meaning |
|---|---|---|
| `-Only 1,3` or `-Only C01,C03` | all | sequence numbers or ids |
| `-ClipsFile` | `clips.json` | |
| `-OutDir` | `video/raw` | |
| `-KeyFile` | `.wavespeed_key` | fallback key file (env var wins) |
| `-CostPerClip` | 0.84 | your per-clip rate, used for the estimate and the guard. **Check your tier; the default is one account's observed price** |
| `-MaxCost` | 20.00 | refuse to start if `todo × CostPerClip` exceeds this |
| `-TimeoutMin` | 20 | poll ceiling per clip |
| `-DryRun` | off | print the plan, submit nothing |

Behaviour that protects money:

- Refuses to run if any clip still references a local file (step 7 not done).
- **Submits each clip exactly once, never retried.** A retry is a second charge.
- Appends `{ts, clip, seq, prediction, out, cost}` to `wavespeed-log.jsonl` **before** polling, so
  a crash after submission still leaves the prediction id to collect later.
- Skips any clip whose output file already exists. Re-run after a failure and only the failed
  clips are submitted.
- One failed clip does not stop the queue. Failures are listed at the end.

Delivered clips arrive as `video/raw/001-c01-slug.mp4 …`. Expect **2560×1440 at 24 fps, roughly
6.5 s for a 6 s request**. The duration parameter is a target, not a contract; step 9 fixes that.

**Verify the first clip with `check_clip.py` before the batch:**

| Flag | Meaning |
|---|---|
| `clip` | the delivered mp4 |
| `--audio <seg.wav>` | the segment that was sent. Cross-correlates it against the clip's audio |
| `--expect-dims WxH` | fail if the resolution was coerced |
| `--frame-out <png>` | write the first frame so it can be compared with the seed by eye |

Audio match above **~0.5** means your segment was reused. Below that, the reference was ignored
and the model invented music; the prompt is probably in the wrong format (step 4, rule 1). Do not
queue the batch until this passes.

### Step 9 — Trim to the timeline

```bash
pwsh -File <skill>/scripts/Trim-Clips.ps1 -DryRun
pwsh -File <skill>/scripts/Trim-Clips.ps1
```

| Flag | Default | Meaning |
|---|---|---|
| `-InDir` / `-OutDir` | `video/raw` / `video/cut` | originals are never modified |
| `-Fps` | 24 | must match what the model delivered |
| `-Skip C20` | none | clips to leave alone, typically one that will be retimed instead |
| `-Crf` | 16 | quality when a re-encode is needed |
| `-Reencode` | off | skip the stream-copy attempt |
| `-FfmpegPath` | PATH | |
| `-DryRun` | off | |

Each clip is cut to `round(timeline_out × fps) − round(timeline_in × fps)` frames. Rounding
boundaries rather than durations is what keeps total drift under half a frame across the whole
sequence. Stream copy is tried first and **verified by frame count**; on mismatch the clip is
re-encoded to the exact count, because `ffmpeg -c copy -t` is not frame-accurate.

Output filenames match the input filenames, so `video/cut/` sorted by name is the timeline.

### Step 10 (optional) — Retime a clip that must stretch

For a clip that has to *cover* a span rather than be trimmed to one, usually an outro under a fade:

```bash
pwsh -File <skill>/scripts/Retime-Clip.ps1 -Source video/raw/020-outro.mp4 -Dest video/cut/020-outro.mp4 -Seconds 17.4167 -Audio audio/outro.wav -Interpolate
```

| Flag | Meaning |
|---|---|
| `-Source` / `-Dest` | required |
| `-Seconds` or `-Frames` | target length, one or the other |
| `-Audio` | mux this file in, replacing the clip's own audio |
| `-Interpolate` | synthesise in-between frames instead of duplicating. Smoother for slow motion; opt-in because it can tear on fast motion |
| `-Fps`, `-Crf`, `-FfmpegPath`, `-DryRun` | as above |

Render such a clip **without** an audio reference (`build_clips.py --no-audio-for 20`) so there is
no invented ambience to slow down, and mux the real audio here. A result a few frames short of
target is normal and correct: interpolation cannot extrapolate past the last source frame, and
those static tail frames are the editor's fade handle. Do not distort the factor to hit the number.

### Step 11 — Assemble

Import `video/cut/` into any editor, sort by filename, lay the clips end to end starting at the
step 3 `--start` time on the original track. Because every clip carries its own audio slice, the
result either sounds like the song or it does not. That is the final check.

---

## 7. Money rules

These are enforced by the scripts, and are also the rules an agent must follow when driving them.

1. Never retry a submission. Only polls are retried.
2. Never queue a batch before one clip has been rendered and checked.
3. Tell the user the total cost before running and let them set `-MaxCost`.
4. Verify submitted parameters landed (resolution, aspect ratio) before waiting on a job.
5. On any failure, re-run the same command. Delivered work is skipped; nothing is re-bought.
6. Prediction ids for every paid job are in `wavespeed-log.jsonl`. If a download failed after a
   successful render, the result can still be fetched by id (see `references/wavespeed-api.md`).

---

## 8. When something goes wrong

Read `<skill>/references/traps.md` first. It documents the failures that produce **silently wrong
output** rather than an error. The ones that bite most:

| Symptom | Cause | Fix |
|---|---|---|
| "no clips matched -Only" | `pwsh -File` passes `A,B` as one string | already handled; make sure you are on `pwsh` 7 |
| Clip has music but it is not yours | prompt not in full-reference format, audio ignored | rewrite with the six-section format; check with `check_clip.py` |
| Square image from a widescreen prompt; CLI returned instantly | newline in an argument truncated it and displaced later flags | already handled by `New-Stills.ps1`; do not call the CLI with raw multi-line prompts |
| `SignatureDoesNotMatch` on upload | space in a file path | already handled; donors are staged through a space-free temp path |
| Trimmed clips are a frame or two long | `ffmpeg -c copy -t` is not frame-accurate | already handled; `Trim-Clips.ps1` verifies and re-encodes |
| Picture drifts ahead of the track over the sequence | durations were rounded instead of boundaries | use `Trim-Clips.ps1`, do not trim by hand to a fixed length |
| Every bar line is one beat off | phase measured on a different window than tempo | re-run `analyze_tempo.py` with `--anchor <known downbeat>` |
| `400 Model not found` from an upload URL | there is no upload endpoint | use `Publish-Refs.ps1` |
| Scripts cannot find ffmpeg | not on PATH | install it or pass `--ffmpeg` / `-FfmpegPath` |
| `grid_sigma` under 3 | tempo fit found nothing usable | analyse a drum-heavy section with `--from/--to`, or ask the user for the tempo |

Further reading in the skill folder:

- `SKILL.md` — the chain with the reasoning behind each stage
- `references/wavespeed-api.md` — endpoints, parameters, response shapes, what clips come back as
- `references/beat-timing.md` — how tempo is measured, why boundaries are rounded

---

## 9. Quick reference

```
Stage    Command                                    Reads                     Writes
0        New-Project.ps1 -Name X                    —                         folders, PROJECT.md, .gitignore
1        analyze_tempo.py track --find-drop         track                     tempo.json
2        split_audio.py track --report              tempo.json                (prints options)
3        split_audio.py track --start S --bars N    tempo.json                audio/*.wav, audio/segments.json
4        (write prompts.md)                         —                         prompts.md
5        New-Stills.ps1                             prompts/stills/*.txt      renders/*.png
6        build_clips.py                             prompts.md, renders, audio/segments.json   clips.json
7        Publish-Refs.ps1 -Bucket B                 clips.json                clips.json (URLs), refs-r2.json
8a       Invoke-WaveSpeed.ps1 -Only 1               clips.json                video/raw/001-*.mp4, wavespeed-log.jsonl
8b       check_clip.py video/raw/001-* --audio …    clip, segment             (report)
8c       Invoke-WaveSpeed.ps1                       clips.json                video/raw/*.mp4
9        Trim-Clips.ps1                             clips.json, video/raw     video/cut/*.mp4
10       Retime-Clip.ps1 (optional)                 one clip                  one clip
```
