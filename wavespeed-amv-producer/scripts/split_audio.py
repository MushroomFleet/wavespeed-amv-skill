"""Split a track into contiguous, sample-exact segments on bar lines.

    python split_audio.py track.mp3 --tempo tempo.json --start 38.9409 --bars 3 --out audio/
    python split_audio.py track.mp3 --tempo tempo.json --report     # show the options, cut nothing

Contiguity is the point. Each segment begins exactly where the previous one ended, so the set
reassembles into the original with no gap and no click, and every clip boundary lands on a
downbeat. Boundaries are computed in samples from the cumulative timeline rather than by
repeatedly adding a float duration, so rounding never accumulates.

--start splits the track into a lead-in section (before the start point) and a main section
(from it), numbering them separately. For a music video that is the intro before the drop and
everything after it. Omit --start to segment the whole track as one run.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import wave

import numpy as np


def find_ffmpeg(explicit=None):
    if explicit:
        return explicit
    p = shutil.which('ffmpeg')
    if p:
        return p
    sys.exit("ffmpeg not found on PATH.\n"
             "  Install it from https://ffmpeg.org/download.html, or pass --ffmpeg <path>.")


def decode_wav(path, ffmpeg, sr=44100):
    import tempfile
    out = os.path.join(tempfile.mkdtemp(), 'full.wav')
    subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-i', path,
                    '-c:a', 'pcm_s16le', '-ar', str(sr), '-ac', '2', out, '-y'], check=True)
    w = wave.open(out)
    n = w.getnframes()
    a = np.frombuffer(w.readframes(n), dtype=np.int16).reshape(-1, 2)
    return a, w.getframerate()


def write_wav(path, seg, sr):
    o = wave.open(path, 'wb')
    o.setnchannels(2)
    o.setsampwidth(2)
    o.setframerate(sr)
    o.writeframes(seg.tobytes())
    o.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('track')
    ap.add_argument('--tempo', default='tempo.json')
    ap.add_argument('--out', default='audio')
    ap.add_argument('--prefix', default='seg')
    ap.add_argument('--bars', type=float, default=3.0, help='bars per segment')
    ap.add_argument('--start', type=float, default=None,
                    help='split point, e.g. a drop. Segments before it are numbered as a lead-in.')
    ap.add_argument('--lead-prefix', default=None, help='prefix for lead-in segments (default <prefix>-intro)')
    ap.add_argument('--tail-mode', choices=['absorb', 'separate', 'drop'], default='separate',
                    help='what to do with the remainder at the end of the track')
    ap.add_argument('--report', action='store_true', help='print segment options and exit')
    ap.add_argument('--ffmpeg', default=None)
    a = ap.parse_args()

    tempo = json.load(open(a.tempo))
    bar = tempo['bar']
    seg_len = bar * a.bars
    dur = tempo['duration']
    db0 = tempo['first_downbeat']

    if a.report:
        print(f"track {dur:.4f}s   bpm {tempo['bpm']}   bar {bar:.5f}s   first downbeat {db0:.4f}s\n")
        print(f"{'bars':>5} {'segment':>10} {'fits in':>9}  {'count over whole track':>24}")
        for b in (1, 2, 3, 4, 6, 8):
            L = bar * b
            fits = [d for d in (4, 5, 6, 7, 8, 10, 12, 15) if d >= L]
            print(f"{b:>5} {L:>9.4f}s {str(fits[0]) + 's' if fits else '   --':>9}  {dur / L:>24.2f}")
        print("\n'fits in' is the shortest standard render length that holds the segment.")
        return

    ffmpeg = find_ffmpeg(a.ffmpeg)
    audio, sr = decode_wav(a.track, ffmpeg)
    total = len(audio)
    os.makedirs(a.out, exist_ok=True)

    runs = []
    if a.start is not None:
        # verify the start point really is on the grid - a start that is not a downbeat makes
        # every later boundary land off the beat
        off = (a.start - db0) / bar
        if abs(off - round(off)) > 0.02:
            print(f"WARNING: --start {a.start} is {abs(off - round(off)):.3f} bars off the downbeat grid.")
            print("         Re-run analyze_tempo.py with --anchor, or pick a real downbeat.\n")
        lead = a.lead_prefix or f"{a.prefix}-intro"
        runs.append((lead, 0.0, a.start))
        runs.append((a.prefix, a.start, dur))
    else:
        runs.append((a.prefix, 0.0, dur))

    manifest = []
    for prefix, t_start, t_end in runs:
        span = t_end - t_start
        n_full = int(span // seg_len)
        rem = span - n_full * seg_len

        # For the lead-in, work BACKWARDS from the start point so the last lead-in segment ends
        # exactly on it. The odd-length segment then lands at the head of the track where it is
        # least disruptive, instead of immediately before the drop.
        if t_start == 0.0 and a.start is not None:
            edges = [t_end - seg_len * i for i in range(n_full, -1, -1)]
            if rem > 0.05:
                edges = [0.0] + edges
        else:
            edges = [t_start + seg_len * i for i in range(n_full + 1)]
            if rem > 0.05:
                if a.tail_mode == 'separate':
                    edges.append(t_end)
                elif a.tail_mode == 'absorb':
                    edges[-1] = t_end

        frames = [int(round(e * sr)) for e in edges]
        frames = [min(max(f, 0), total) for f in frames]
        for i in range(len(frames) - 1):
            s, e = frames[i], frames[i + 1]
            if e - s < sr * 0.1:
                continue
            name = f"{prefix}-{i + 1:02d}.wav"
            write_wav(os.path.join(a.out, name), audio[s:e], sr)
            manifest.append({
                'file': os.path.join(a.out, name).replace(os.sep, '/'),
                'index': i + 1, 'group': prefix,
                'start': round(s / sr, 5), 'end': round(e / sr, 5),
                'seconds': round((e - s) / sr, 5), 'frames': e - s,
            })

    json.dump({'track': os.path.basename(a.track), 'sample_rate': sr,
               'bar': bar, 'bars_per_segment': a.bars, 'segments': manifest},
              open(os.path.join(a.out, 'segments.json'), 'w'), indent=1)

    print(f"{len(manifest)} segments -> {a.out}/\n")
    print(f"{'file':<28} {'start':>10} {'end':>10} {'seconds':>9}")
    for m in manifest:
        print(f"{os.path.basename(m['file']):<28} {m['start']:>10.4f} {m['end']:>10.4f} {m['seconds']:>9.5f}")
    covered = sum(m['frames'] for m in manifest) / sr
    print(f"\ncovered {covered:.4f}s of {dur:.4f}s   contiguous: "
          f"{all(manifest[i]['end'] == manifest[i + 1]['start'] for i in range(len(manifest) - 1) if manifest[i]['group'] == manifest[i + 1]['group'])}")
    print(f"wrote {a.out}/segments.json")


if __name__ == '__main__':
    main()
