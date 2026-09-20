# Beat timing

Why the timing stages work the way they do, and how to choose their settings.

## The idea

A music video is a sequence of clips whose boundaries land on musical boundaries. If every clip
is exactly N bars long and starts on a downbeat, the cuts land with the music for free — no
nudging in the edit, no drift by the end.

That requires three things to be true, and each is a stage:

1. the tempo and downbeat grid are **measured**, not assumed
2. the audio is cut into contiguous N-bar segments on that grid
3. the delivered clips are trimmed to lengths derived from the same grid

## Measuring tempo

`analyze_tempo.py` builds a log-compressed spectral-flux onset envelope, then fits tempo by
**amplitude-weighted phase locking**: for each candidate period, sum `env_i · e^(2πi·t_i/period)`
and take the magnitude. The winner is the period the onsets cluster around.

This is used rather than plain autocorrelation because ACF resolution is limited by lag spacing.
At ~125 BPM with a 128-sample hop, adjacent lags are about 1.5 BPM apart — enough error to drift
a second across a three-minute track. Phase locking resolves to any grid step you ask for.

**Check the confidence figure.** `grid_sigma` is how many standard deviations the on-beat energy
sits above off-beat energy. Comfortably above 3 means a real grid. Near or below it means the fit
found nothing, and building a timeline on that number will produce cuts that land nowhere.

### Bar phase is the part that goes wrong quietly

Knowing the beat period does not tell you which beat is beat one. The script scores each candidate
phase by accent energy and picks the strongest — but two rules matter:

- **Measure phase on the same window as the tempo fit.** Fitting on the drop section while
  measuring phase over the whole track lets a drum-less intro pull the answer a beat off, and then
  every bar line is wrong by one beat.
- **Prefer `--anchor` when you can.** If the user can point at a real downbeat — a drop, a
  section change, the first kick — phase-locking the grid through it is better evidence than any
  accent statistic. `--find-drop` proposes a candidate and snaps it to the grid for confirmation.

## Choosing a bar count

`split_audio.py --report` prints the options. Pick a segment length that fits inside a render
length the model supports, with a little to trim:

```
 bars    segment   fits in
    2    3.8452s        4s
    3    5.7678s        6s
    4    7.6903s        8s
```

3 bars into a 6-second render is a good default at most dance tempos: the clip has ~0.2s of slack
to trim, and three bars is long enough for a gesture to read without outstaying its welcome.

Longer segments mean fewer clips and less money, but each clip has to hold attention longer.
Shorter segments cut harder and cost more.

## Contiguity, and why it is not fussiness

Segments are cut from **cumulative sample offsets**, so each begins exactly where the previous
ended. Two things follow:

- the set reassembles into the original track with no gap and no click
- every clip boundary is a downbeat, because they are all derived from one grid rather than from
  repeated addition of a float

Adding a duration repeatedly instead accumulates rounding, and a few milliseconds per clip becomes
audible over twenty.

## Frames: round boundaries, not durations

This is the one that catches people.

A bar is rarely a whole number of frames. At 124.832 BPM and 24fps, three bars is **138.43
frames**. You cannot render 138.43 frames.

Rounding each clip's **length** gives a flat 138 frames every time — losing 0.018s per clip, which
accumulates to **0.32s** of picture running ahead of the track over twenty clips. Audible and
visible.

Rounding each **timeline boundary** instead:

```
frames = round(timeline_out × fps) − round(timeline_in × fps)
```

gives lengths that alternate 138, 139, 138, 139… Each individual clip is within half a frame of
its true length, and because every boundary is derived from the same absolute grid, the error
never accumulates. Total across twenty clips: **0.31 frames**.

Same operation, applied one level up. `Trim-Clips.ps1` does this.

## The clip that stretches instead of trimming

Sequences often end on a clip that has to *cover* a long tail — an outro under a fade. That one
gets `Retime-Clip.ps1` rather than a trim, and should be rendered **without an audio reference**
so the model has no invented ambience to slow down. Mux the real audio in during the retime.

Expect it to land a few frames under target; interpolation cannot extrapolate past the last
source frame. Those static tail frames are normally exactly what the editor fades across, so the
shortfall is a feature. Do not distort the retime factor to remove it.
