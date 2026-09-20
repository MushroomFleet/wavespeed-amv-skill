"""Check a delivered clip against what was asked for.

    python check_clip.py video/raw/001-c01-foo.mp4 --audio audio/seg-01.wav --image renders/a.png

Three things are worth verifying on the first clip of a run, before a batch is queued:

  resolution   did the model honour the aspect ratio and size, or silently coerce them
  audio reuse  is the returned clip carrying YOUR audio segment, or something it invented
  first frame  does the clip actually start from the seed image

The audio check is the one that is easy to get wrong by eye. A clip can come back with plausible
music that is not the segment you sent - which means the reference was ignored and nothing will
line up in the edit. Cross-correlation settles it: above ~0.5 the segment was reused.
"""
import argparse
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


def probe(path, ffmpeg):
    r = subprocess.run([ffmpeg, '-hide_banner', '-i', path], capture_output=True, text=True)
    s = r.stderr
    import re
    dim = re.search(r'(\d{3,5})x(\d{3,5})', s)
    fps = re.search(r'([\d.]+) fps', s)
    dur = re.search(r'Duration: (\d+):(\d+):([\d.]+)', s)
    frames = subprocess.run([ffmpeg, '-hide_banner', '-i', path, '-map', '0:v:0', '-c', 'copy',
                             '-f', 'null', '-'], capture_output=True, text=True).stderr
    fm = re.findall(r'frame=\s*(\d+)', frames)
    return {
        'dims': dim.group(0) if dim else '?',
        'fps': float(fps.group(1)) if fps else 0.0,
        'seconds': (int(dur.group(1)) * 3600 + int(dur.group(2)) * 60 + float(dur.group(3))) if dur else 0.0,
        'frames': int(fm[-1]) if fm else -1,
        'has_audio': 'Audio:' in s,
    }


def mono(path, ffmpeg):
    raw = os.path.join(tempfile.mkdtemp(), 'a.raw')
    subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-i', path,
                    '-ac', '1', '-ar', str(SR), '-f', 'f32le', raw, '-y'], check=True)
    return np.fromfile(raw, dtype=np.float32)


def correlate(a, b):
    n = min(len(a), len(b))
    if n < SR // 2:
        return 0.0, 0.0
    x = a[:n] - a[:n].mean()
    y = b[:n] - b[:n].mean()
    best = (0.0, 0.0)
    for off in range(-SR // 5, SR // 5 + 1, SR // 50):
        if off >= 0:
            xx, yy = x[off:], y[:n - off]
        else:
            xx, yy = x[:n + off], y[-off:]
        m = min(len(xx), len(yy))
        if m < SR // 2:
            continue
        d = np.linalg.norm(xx[:m]) * np.linalg.norm(yy[:m])
        if d == 0:
            continue
        c = float(np.dot(xx[:m], yy[:m]) / d)
        if abs(c) > abs(best[0]):
            best = (c, off / SR)
    return best


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('clip')
    ap.add_argument('--audio', default=None, help='the segment that was sent as a reference')
    ap.add_argument('--expect-dims', default=None, help='e.g. 2560x1440')
    ap.add_argument('--frame-out', default=None, help='write the first frame here to compare with the seed')
    ap.add_argument('--ffmpeg', default=None)
    a = ap.parse_args()

    ffmpeg = find_ffmpeg(a.ffmpeg)
    info = probe(a.clip, ffmpeg)
    print(f"clip        {os.path.basename(a.clip)}")
    print(f"dimensions  {info['dims']}")
    print(f"frame rate  {info['fps']} fps")
    print(f"length      {info['seconds']:.3f}s  ({info['frames']} frames)")
    print(f"audio track {'yes' if info['has_audio'] else 'NO'}")

    problems = []
    if a.expect_dims and info['dims'] != a.expect_dims:
        problems.append(f"dimensions are {info['dims']}, expected {a.expect_dims} - the API may have "
                        f"coerced the aspect ratio, which usually means a parameter did not land")

    if a.audio:
        if not info['has_audio']:
            problems.append("an audio reference was sent but the clip came back with no audio track")
        else:
            c, off = correlate(mono(a.clip, ffmpeg), mono(a.audio, ffmpeg))
            print(f"\naudio match {c:+.4f} at offset {off:+.3f}s")
            if abs(c) > 0.5:
                print("            -> your segment was reused as the clip's audio")
            elif abs(c) > 0.2:
                print("            -> partially related; listen before trusting it")
            else:
                print("            -> NOT your segment. The reference was ignored and the model")
                print("               invented its own audio; nothing will line up in the edit.")
                problems.append("audio reference was not reused")

    if a.frame_out:
        subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-i', a.clip,
                        '-frames:v', '1', a.frame_out, '-y'], check=True)
        print(f"\nfirst frame written to {a.frame_out} - compare it with the seed image by eye")

    print()
    if problems:
        print("PROBLEMS:")
        for p in problems:
            print("  - " + p)
        raise SystemExit(1)
    print("no problems found")


if __name__ == '__main__':
    main()
