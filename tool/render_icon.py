#!/usr/bin/env python3
"""Render the launcher icon PNGs in assets/icon/ from the vector design below.

The mark is a G drawn as a commit graph: an arc that starts at a ring commit and
ends in a crossbar with a solid amber commit, on an indigo gradient. Chromium
rasterises the SVG so edges are anti-aliased; flutter_launcher_icons (run by
tool/bootstrap.py) then turns the PNGs into the platform icon sets.

  python3 tool/render_icon.py --chromium /path/to/chrome-or-headless_shell
"""
from __future__ import annotations

import argparse
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets' / 'icon'
ACCENT = '#FFC24B'
# Full-bleed icons (iOS, legacy Android, Play) and the adaptive foreground use
# different glyph scales. An adaptive layer is 108dp with only the central 66dp
# circle guaranteed visible, and flutter_launcher_icons insets the foreground
# image by 16% on each side, so the image covers the central 68% of the layer.
# ADAPTIVE_SCALE gives the glyph the same share of the visible icon as FULL_SCALE.
FULL_SCALE = 1.10
ADAPTIVE_SCALE = 1.08
INSET_COVERAGE = .68
SAFE_RADIUS = 1024 * (33 / 108) / INSET_COVERAGE

BACKGROUND = '''<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
<stop offset="0" stop-color="#5B86FF"/><stop offset=".55" stop-color="#3B43D9"/><stop offset="1" stop-color="#5A2DB8"/>
</linearGradient>
<radialGradient id="glow" cx=".28" cy=".2" r=".8">
<stop offset="0" stop-color="#fff" stop-opacity=".20"/><stop offset="1" stop-color="#fff" stop-opacity="0"/>
</radialGradient>'''


def glyph(scale: float) -> tuple[str, str, float]:
    """Mask body (white shows, black cuts the ring's hole), the accent commit,
    and the glyph's furthest reach from the centre, in a 1024 box."""
    cx = cy = 512
    r, w = 214 * scale, 88 * scale
    start = math.radians(-42)
    sx, sy = cx + r * math.cos(start), cy + r * math.sin(start)
    ex, ey = cx + r, cy
    bar = cx + 18 * scale
    ring, hole, dot = .80 * w, .36 * w, .70 * w
    mask = (f'<path d="M {sx:.1f} {sy:.1f} A {r:.1f} {r:.1f} 0 1 0 {ex:.1f} {ey:.1f} L {bar:.1f} {ey:.1f}" '
            f'fill="none" stroke="#fff" stroke-width="{w:.1f}" stroke-linecap="round" stroke-linejoin="round"/>'
            f'<circle cx="{sx:.1f}" cy="{sy:.1f}" r="{ring:.1f}" fill="#fff"/>'
            f'<circle cx="{sx:.1f}" cy="{sy:.1f}" r="{hole:.1f}" fill="#000"/>')
    accent = f'<circle cx="{bar:.1f}" cy="{ey:.1f}" r="{dot:.1f}" fill="{ACCENT}"/>'
    return mask, accent, max(r + w / 2, r + ring)


def svg(*, background: bool, scale: float | None = None, monochrome: bool = False) -> str:
    defs, body = [], []
    if background:
        defs.append(BACKGROUND)
        body.append('<rect width="1024" height="1024" fill="url(#bg)"/>'
                    '<rect width="1024" height="1024" fill="url(#glow)"/>')
    if scale is not None:
        mask, accent, _ = glyph(scale)
        defs.append('<mask id="g" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">'
                    f'<rect width="1024" height="1024" fill="#000"/>{mask}</mask>')
        body.append('<rect width="1024" height="1024" fill="#fff" mask="url(#g)"/>')
        # A themed (monochrome) icon is a single alpha shape, so the commit joins it.
        body.append(accent.replace(ACCENT, '#fff') if monochrome else accent)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            f'<defs>{"".join(defs)}</defs>{"".join(body)}</svg>')


def render(chromium: str, content: str, out: Path, size: int, work: Path) -> None:
    page = work / f'{out.stem}.html'
    page.write_text('<!doctype html><html><head><style>html,body{margin:0;background:transparent}'
                    f'svg{{display:block;width:{size}px;height:{size}px}}</style></head>'
                    f'<body>{content}</body></html>', encoding='utf-8')
    subprocess.run([chromium, '--headless', '--no-sandbox', '--disable-gpu', '--hide-scrollbars',
                    f'--window-size={size},{size}', '--default-background-color=00000000',
                    f'--screenshot={out}', page.as_uri()],
                   check=True, capture_output=True, timeout=120)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--chromium', default=os.environ.get('CHROMIUM') or shutil.which('chromium'),
                        help='Chromium, Chrome or headless_shell binary (default: $CHROMIUM or chromium on PATH)')
    args = parser.parse_args()
    if not args.chromium:
        parser.error('no Chromium found; pass --chromium')
    if glyph(ADAPTIVE_SCALE)[2] > SAFE_RADIUS:
        raise SystemExit('adaptive glyph leaves the 66dp safe zone')
    targets = {
        'icon.png': (svg(background=True, scale=FULL_SCALE), 1024),
        'play_512.png': (svg(background=True, scale=FULL_SCALE), 512),
        'icon_background.png': (svg(background=True), 1024),
        'icon_foreground.png': (svg(background=False, scale=ADAPTIVE_SCALE), 1024),
        'icon_monochrome.png': (svg(background=False, scale=ADAPTIVE_SCALE, monochrome=True), 1024),
    }
    with tempfile.TemporaryDirectory() as work:
        for name, (content, size) in targets.items():
            render(args.chromium, content, OUT / name, size, Path(work))
            print(f'wrote {(OUT / name).relative_to(ROOT)}')


if __name__ == '__main__':
    main()
