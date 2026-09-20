# Traps

Failure modes that produce **silently wrong output or wasted money** rather than an error. Each
one cost something real to find. Check here before debugging anything odd.

## Paid-API traps

### A retry re-charges

Retrying a submission that timed out or returned oddly bills again for an identical job. Retry
logic belongs on the *poll*, never on the *submit*. If a submission genuinely fails, surface it
and let the user decide.

### A crash after submitting loses the job

The money is spent the moment the submission returns an id. If the process dies before the poll
finishes, the render still happens and still bills — but nothing on disk says so. **Log the
prediction id before polling starts.** `wavespeed-log.jsonl` exists for this.

### A coerced parameter still costs full price

APIs quietly clamp what they do not like. A job submitted with `aspect_ratio: 16:9` that comes
back `1:1` renders happily and bills fully. Read the submitted job's parameters back and check
them *before* waiting on it — the wait is where the time goes, and the check is one call.

### Queueing a batch before eyeballing one

Every batch mistake multiplies. Render one, look at it, then queue the rest.

## CLI argument traps

### A newline in an argument can truncate it *and* eat the flags after it

The Higgsfield CLI splits an argument on newlines. A three-paragraph prompt passed with real line
breaks arrives as its first paragraph only, and the remaining paragraphs become stray positional
arguments that displace `--aspect_ratio`, `--resolution` and `--wait`. The job runs at defaults,
from a third of the prompt, with no error anywhere.

Symptom: a square image from a prompt that asked for widescreen, and a command that returns
instantly instead of waiting.

Fix: collapse prompts to one line before submission. Keep the source files readable —
`(Get-Content $f -Raw) -replace '\s+', ' '` at the call site.

### A space in a file path breaks signed uploads

The Higgsfield CLI signs its S3 PUT using the file path. On a machine whose home directory
contains a space (`C:\Users\First Last\...`), every upload fails with `SignatureDoesNotMatch`
and takes the whole generate call with it.

Fix: copy the file to a space-free temp path, upload that, and pass the returned media id rather
than a path.

### `pwsh -File` passes comma lists as one string

`-Only A,B` arrives as the single string `"A,B"`, not an array, so a naive `-in` test matches
nothing and the script reports "no clips matched". Split on commas inside the script as well as
declaring `[string[]]`.

## ffmpeg traps

### `-c copy -t <duration>` is not frame-accurate

Stream copy cuts on packet boundaries, so a copy bounded by `-t` routinely returns one or two
frames more than asked for. A trim that trusts the flag produces clips of the wrong length with
no error at all.

Fix: verify the frame count after copying and re-encode with `-frames:v N` on mismatch. Copy-first
is still worth trying — it is lossless and instant when it happens to land.

### `minterpolate` cannot extrapolate past the last frame

A heavy slow-down lands a few frames short of the target, because interpolation has no source
material after the final input frame. `tpad=stop_mode=clone` is the intended fill.

More importantly: **a small shortfall is usually correct.** A clip written to end at rest has
static tail frames, and those frames are the editor's cross-fade handle. Do not distort the
retime factor to satisfy the number — that changes the motion to fix something nobody watches.

### ffmpeg may not be on PATH

Some environments only have a copy bundled inside another tool's directory, often a temp
extraction that gets cleaned up without warning. Pointing a script at one explicitly is fine;
hardcoding one as a fallback is not, because the path is machine-specific and the failure it
causes later is silent. The scripts here require ffmpeg on PATH or an explicit `--ffmpeg` /
`-FfmpegPath` argument, and say so plainly when they cannot find it.

## Timing traps

### Rounding durations instead of boundaries

A musical bar is rarely a whole number of frames. Rounding each clip's *length* loses the same
fraction every time and the error accumulates — a third of a second over twenty clips at 24fps.
Round each *timeline boundary* instead: `round(out × fps) − round(in × fps)`. Clip lengths then
alternate (138, 139, 138…) and total error stays under half a frame.

### Trusting a round number from the user

"The drop is at 38 seconds" means *look near 38 seconds*. Measured, it was 38.9409s — and 38.0s
landed in a silent gap. Every cut downstream inherits this number, so measure it and confirm the
measurement with the user.

### Measuring bar phase over a different window than the tempo fit

Fitting tempo on a section but deriving bar phase from the whole track puts the two out of
agreement. An intro with a different accent pattern pulls the phase a beat off, and then every
bar line in the timeline is wrong by one beat. Use the same window for both, and prefer
`--anchor` with a known downbeat over any accent measurement.

## Hosting traps

### The R2 dev bucket is public and unauthenticated

Anyone holding a URL can fetch the assets. The hostname hash is unguessable so practical risk is
low, but for unreleased work it is the user's decision, not a default. Say so, and offer
`Publish-Refs.ps1 -Teardown` when the run finishes.

### A 400 is not proof an endpoint exists

`POST /api/v3/media/upload` on WaveSpeed returns 400, which looks like a malformed request to a
real endpoint. It is not — `/api/v3/<anything>` routes as a model path, and the real response is
`"Model not found"`. There is no upload endpoint. Probe with a valid-looking body before
concluding an endpoint is there.
