"""Build clips.json - the queue every later stage reads.

Pairs prompt blocks with reference images and audio segments in order, assigns sequence-ordered
output filenames, and computes each clip's timeline position from the audio segments.

    python build_clips.py --prompts prompts.md --images renders --audio audio
    python build_clips.py --prompts intro.md,body.md --images renders/intro,renders --audio audio

Prompts are read from fenced ```text blocks in markdown, in document order - the format the
minimaxh3-enh skill emits. Images are taken in sorted order from each directory, or listed
explicitly with --image-list. Audio comes from segments.json written by split_audio.py.

Ordering is everything here. Show the printed table to the user and get it confirmed before
anything is rendered: one mispairing shifts every clip after it, and you only find out after
paying for all of them.
"""
import argparse
import glob
import json
import os
import re
import sys

BLOCK = re.compile(r"```text\n(.*?)\n```", re.S)
SLUG = re.compile(r'[^a-z0-9]+')


ORDINAL = re.compile(r'^\s*(?:clip|shot|scene|cut|seq|sequence|part)?\s*[-#]?\s*\d+[a-z]?\s*[-–—:.)]*\s*',
                     re.I)


def slug(s, n=5):
    """Filename-safe slug from a heading.

    Strips a leading ordinal ("Clip 01 —", "Shot 3:", "12.") because the output filename already
    carries its own sequence number, and doubling it up gives names like 001-c01-clip-01-foo.
    """
    s = ORDINAL.sub('', s)
    words = SLUG.sub('-', s.lower()).strip('-').split('-')
    return '-'.join([w for w in words if w][:n]) or 'clip'


def read_prompts(paths):
    """Return [(prompt_body, nearest_heading_above_it), ...] in document order.

    The heading has to be the NEAREST ONE ABOVE each block, not the Nth heading in the file.
    Prompt documents carry front-matter sections ("## Timeline", "## House rules") that have no
    block under them, so zipping headings against blocks by index slides every name one or more
    places out and each clip gets titled after some unrelated section.
    """
    out = []
    for p in paths:
        if not os.path.exists(p):
            sys.exit(f"prompt file not found: {p}")
        text = open(p, encoding='utf-8').read()
        heads = [(m.start(), m.group(1).strip()) for m in re.finditer(r'^#{1,4}\s+(.+)$', text, re.M)]
        found = False
        for m in BLOCK.finditer(text):
            prior = [h for pos, h in heads if pos < m.start()]
            out.append((m.group(1), prior[-1] if prior else f'clip {len(out) + 1}'))
            found = True
        if not found:
            sys.exit(f"no ```text blocks found in {p}")
    return out


def collect(spec, exts):
    """spec is a comma-separated list of directories and/or explicit files, kept in order."""
    files = []
    for part in spec.split(','):
        part = part.strip()
        if not part:
            continue
        if os.path.isdir(part):
            got = []
            for e in exts:
                got += glob.glob(os.path.join(part, f'*{e}'))
            files += sorted(got)
        elif os.path.exists(part):
            files.append(part)
        else:
            sys.exit(f"not found: {part}")
    return [f.replace(os.sep, '/') for f in files]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--prompts', required=True, help='markdown file(s), comma separated, in order')
    ap.add_argument('--images', required=True, help='directories and/or files, comma separated, in order')
    ap.add_argument('--audio', default=None, help='directory holding segments.json, or omit for no audio')
    ap.add_argument('--out', default='clips.json')
    ap.add_argument('--outdir-name', default='', help='optional prefix inside output filenames')
    ap.add_argument('--duration', type=int, default=6)
    ap.add_argument('--resolution', default='2k')
    ap.add_argument('--aspect-ratio', default='16:9')
    ap.add_argument('--no-audio-for', default='', help='clip indexes (1-based) to leave without audio')
    a = ap.parse_args()

    prompts = read_prompts([p.strip() for p in a.prompts.split(',')])
    images = collect(a.images, ('.png', '.jpg', '.jpeg', '.webp'))

    segs = []
    if a.audio:
        sf = os.path.join(a.audio, 'segments.json')
        if not os.path.exists(sf):
            sys.exit(f"{sf} not found - run split_audio.py first, or omit --audio")
        segs = json.load(open(sf))['segments']

    n = len(prompts)
    if len(images) < n:
        sys.exit(f"{n} prompts but only {len(images)} images. Every clip needs a reference image.")
    if len(images) > n:
        print(f"note: {len(images)} images for {n} prompts - using the first {n} in sorted order.\n")
    if segs and len(segs) < n:
        print(f"note: {len(segs)} audio segments for {n} prompts - the last {n - len(segs)} clip(s) get no audio.\n")

    skip_audio = {int(x) for x in a.no_audio_for.split(',') if x.strip().isdigit()}

    clips = []
    for i in range(n):
        body, head = prompts[i]
        seg = segs[i] if i < len(segs) else None
        use_audio = seg is not None and (i + 1) not in skip_audio
        sl = slug(head)
        cid = f"C{i + 1:02d}"
        clips.append({
            'seq': i + 1, 'id': cid, 'slug': sl,
            'prompt': body,
            'image': images[i],
            'audio': seg['file'] if use_audio else None,
            'duration': a.duration, 'resolution': a.resolution, 'aspect_ratio': a.aspect_ratio,
            'timeline_in': seg['start'] if seg else round(i * a.duration, 4),
            'timeline_out': seg['end'] if seg else round((i + 1) * a.duration, 4),
            'cut': seg['seconds'] if seg else float(a.duration),
            'out': f"{a.outdir_name}{i + 1:03d}-{cid.lower()}-{sl}.mp4",
        })

    json.dump(clips, open(a.out, 'w', encoding='utf-8'), indent=1, ensure_ascii=False)

    print(f"{a.out}: {len(clips)} clips\n")
    print(f"{'seq':>3} {'id':<5} {'image':<34} {'audio':<22} {'in':>9} {'out':>9} {'cut':>8}")
    for c in clips:
        print(f"{c['seq']:>3} {c['id']:<5} {os.path.basename(c['image'])[:33]:<34} "
              f"{(os.path.basename(c['audio']) if c['audio'] else '-')[:21]:<22} "
              f"{c['timeline_in']:>9.3f} {c['timeline_out']:>9.3f} {c['cut']:>8.4f}")
    total = clips[-1]['timeline_out'] - clips[0]['timeline_in']
    print(f"\ntimeline {clips[0]['timeline_in']:.3f} -> {clips[-1]['timeline_out']:.3f} ({total:.3f}s)")
    print("\nCheck this pairing before rendering anything. One row out of order means every clip")
    print("after it is wrong, and that only becomes visible after paying for all of them.")


if __name__ == '__main__':
    main()
