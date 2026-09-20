"""Measure tempo, bar length and the downbeat grid of a track.

Writes tempo.json for split_audio.py to consume. Reports a confidence figure so a bad
measurement is visible rather than silently becoming a timeline.

    python analyze_tempo.py track.mp3 --out tempo.json
    python analyze_tempo.py track.mp3 --find-drop
    python analyze_tempo.py track.mp3 --from 40 --to 120      # analyse a section only

Method: decode to mono, build a log-compressed spectral-flux onset envelope, then fit tempo by
amplitude-weighted phase locking over a fine BPM grid. Phase locking is used rather than plain
autocorrelation because ACF resolution is limited by lag spacing - at ~125 BPM adjacent lags are
1.5 BPM apart, which is enough error to drift a second over a three-minute track.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np

SR = 22050


def find_ffmpeg(explicit=None):
    if explicit:
        return explicit
    p = shutil.which('ffmpeg')
    if p:
        return p
    sys.exit("ffmpeg not found on PATH.\n"
             "  Install it from https://ffmpeg.org/download.html, or pass --ffmpeg <path>.")


def decode(path, ffmpeg):
    raw = os.path.join(tempfile.mkdtemp(), 'a.raw')
    subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-i', path,
                    '-ac', '1', '-ar', str(SR), '-f', 'f32le', raw, '-y'], check=True)
    return np.fromfile(raw, dtype=np.float32)


def onset_envelope(x, hop=128, win=2048):
    """Log-compressed spectral flux with a max-filtered reference.

    The max filter across neighbouring frequency bins suppresses vibrato and slow pitch drift
    from registering as onsets, which otherwise smears the grid on sustained material.
    """
    from scipy.ndimage import maximum_filter1d
    n = (len(x) - win) // hop
    if n < 10:
        sys.exit("track too short to analyse")
    w = np.hanning(win)
    S = np.empty((n, win // 2 + 1), dtype=np.float32)
    for i in range(n):
        S[i] = np.abs(np.fft.rfft(x[i * hop:i * hop + win] * w))
    L = np.log1p(1000 * S)
    ref = maximum_filter1d(L[:-2], size=3, axis=1)
    d = L[2:] - ref
    d[d < 0] = 0
    env = d.sum(axis=1)
    fps = SR / hop
    # subtract a local mean so loud sections do not dominate the fit
    k = max(1, int(fps * 0.5))
    env = env - np.convolve(env, np.ones(k) / k, 'same')
    env[env < 0] = 0
    t = np.arange(len(env)) / fps + (2 * hop / SR)
    return env, t, fps


def fit_tempo(env, t, lo=60.0, hi=200.0, step=0.002):
    """Amplitude-weighted phase locking: |sum env_i * exp(2*pi*i*t_i/period)|.

    Uses the whole envelope rather than detected peaks, so it stays stable on material where
    peak-picking is unreliable, and resolves far finer than autocorrelation lag spacing.
    """
    e = env / (env.max() or 1.0)
    best = None
    for bpm in np.arange(lo, hi, step):
        per = 60.0 / bpm
        z = (e * np.exp(2j * np.pi * t / per)).sum()
        r = abs(z) / (e.sum() or 1.0)
        if best is None or r > best[0]:
            best = (r, bpm, (np.angle(z) / (2 * np.pi)) % 1.0)
    return best


def grid_confidence(env, t, anchor, beat, fps):
    """How many sigma the on-beat energy sits above off-beat energy. Below ~3 the grid is junk."""
    beats = np.arange(anchor, t[-1], beat)
    beats = beats[beats > t[0]]
    idx = np.clip(((beats - t[0]) * fps).round().astype(int), 0, len(env) - 1)
    on = env[idx].mean()
    rng = np.random.default_rng(0)
    off = []
    for _ in range(200):
        jitter = rng.uniform(0.25, 0.45, len(beats)) * rng.choice([-1, 1], len(beats)) * beat
        j = np.clip(((beats + jitter - t[0]) * fps).round().astype(int), 0, len(env) - 1)
        off.append(env[j].mean())
    off = np.array(off)
    return on, off.mean(), (on - off.mean()) / (off.std() or 1.0)


def bar_phase(env, t, offset, beat, fps, beats_per_bar):
    """Which beat of the bar carries the accent, as an offset from the GLOBAL grid origin.

    The phase is derived from each beat's absolute index on the grid - round((b - offset)/beat)
    - not from its position within the analysis window. Slicing the in-window beat array instead
    makes the answer depend on where the window happens to start, which silently shifts every
    bar line when --from changes.
    """
    beats = np.arange(offset, t[-1], beat)
    beats = beats[beats > t[0]]
    k = np.round((beats - offset) / beat).astype(int) % beats_per_bar
    idx = np.clip(((beats - t[0]) * fps).round().astype(int), 0, len(env) - 1)
    scores = [float(env[idx[k == p]].mean()) if np.any(k == p) else 0.0
              for p in range(beats_per_bar)]
    return int(np.argmax(scores)), scores


def find_drop(env, t):
    """Largest sustained energy jump - a candidate section boundary for the user to confirm."""
    fps = 1 / (t[1] - t[0])
    w = int(fps * 2)
    if len(env) < 4 * w:
        return None
    best = (0, 0.0)
    for i in range(w, len(env) - w):
        after = env[i:i + w].mean()
        before = env[i - w:i].mean()
        jump = after - before
        if jump > best[0]:
            best = (jump, t[i])
    return best[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('track')
    ap.add_argument('--out', default='tempo.json')
    ap.add_argument('--min-bpm', type=float, default=60.0)
    ap.add_argument('--max-bpm', type=float, default=200.0)
    ap.add_argument('--beats-per-bar', type=int, default=4)
    ap.add_argument('--from', dest='t0', type=float, default=None, help='analyse from this second')
    ap.add_argument('--to', dest='t1', type=float, default=None, help='analyse up to this second')
    ap.add_argument('--anchor', type=float, default=None,
                    help='a known downbeat in seconds - phase-locks the grid through it instead '
                         'of guessing the bar phase from accent energy')
    ap.add_argument('--find-drop', action='store_true')
    ap.add_argument('--ffmpeg', default=None)
    a = ap.parse_args()

    ffmpeg = find_ffmpeg(a.ffmpeg)
    x = decode(a.track, ffmpeg)
    duration = len(x) / SR
    env, t, fps = onset_envelope(x)

    drop = find_drop(env, t) if a.find_drop else None

    # fit on a section if asked - a build-up with no drums drags the fit around
    m = np.ones(len(t), bool)
    if a.t0 is not None:
        m &= t >= a.t0
    if a.t1 is not None:
        m &= t <= a.t1
    r, bpm, ph = fit_tempo(env[m], t[m], a.min_bpm, a.max_bpm)

    beat = 60.0 / bpm
    bar = beat * a.beats_per_bar
    offset = (-ph * beat) % beat

    # Confidence and bar phase are measured on the SAME window as the tempo fit. Measuring them
    # over the whole track while fitting on a section puts them out of agreement - an intro with
    # a different accent pattern will pull the bar phase a beat off, and then every bar line in
    # the timeline is wrong by one beat.
    env_w, t_w = env[m], t[m]

    if a.anchor is not None:
        # A known downbeat is better evidence than any accent measurement. Phase-lock the grid
        # through it and skip the guess. Use this whenever the user can point at a real downbeat.
        k = round((a.anchor - offset) / beat)
        offset = a.anchor - k * beat
        phase = 0
        downbeat0 = a.anchor - round((a.anchor - offset) / bar) * bar
        phase_scores = None
    else:
        phase, phase_scores = bar_phase(env_w, t_w, offset, beat, fps, a.beats_per_bar)
        downbeat0 = offset + phase * beat
        # wind back to the first downbeat at or after t=0
        downbeat0 -= bar * np.floor(downbeat0 / bar)

    on, off, sigma = grid_confidence(env_w, t_w, offset, beat, fps)

    out = {
        'track': os.path.basename(a.track),
        'duration': round(duration, 4),
        'bpm': round(float(bpm), 4),
        'beat': round(float(beat), 6),
        'beats_per_bar': a.beats_per_bar,
        'bar': round(float(bar), 6),
        'first_downbeat': round(float(downbeat0), 4),
        'lock_strength': round(float(r), 4),
        'grid_sigma': round(float(sigma), 2),
        'bar_phase_scores': ([round(s, 2) for s in phase_scores] if phase_scores else None),
        'anchored': a.anchor is not None,
    }
    if drop is not None:
        out['drop_candidate'] = round(float(drop), 4)
        # snap the candidate to the nearest downbeat - a drop lands on one
        k = round((drop - downbeat0) / bar)
        out['drop_snapped'] = round(float(downbeat0 + k * bar), 4)

    json.dump(out, open(a.out, 'w'), indent=1)

    print(f"track            {out['track']}  {duration:.3f}s")
    print(f"tempo            {bpm:.3f} BPM   beat {beat:.5f}s   bar {bar:.5f}s ({a.beats_per_bar}/4)")
    print(f"first downbeat   {downbeat0:.4f}s")
    print(f"lock strength    {r:.4f}")
    print(f"grid confidence  {sigma:.2f} sigma  (on-beat {on:.1f} vs off-beat {off:.1f})")
    if a.anchor is not None:
        print(f"grid anchored on  {a.anchor}s (supplied downbeat)")
    if sigma < 3:
        print("\n  WARNING: weak grid. Do not build a timeline on this - ask the user for the tempo.")
    if drop is not None:
        print(f"\ndrop candidate   {drop:.4f}s  -> snapped to downbeat {out['drop_snapped']:.4f}s")
        print("  Confirm this with the user before using it as a start point.")
    print(f"\nwrote {a.out}")


if __name__ == '__main__':
    main()
