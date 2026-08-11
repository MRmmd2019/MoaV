#!/usr/bin/env python3
"""Render assets/star-history.svg from this repo's own stargazer timestamps.

Why we generate it instead of embedding a hosted chart: on 2026-06-30 GitHub
restricted /repos/{owner}/{repo}/stargazers to a repo's own admins and
collaborators, because the data was being harvested for spam. A third-party
chart service is neither, so hosted embeds render blank. GITHUB_TOKEN in this
repo's own Actions *is* admin, so the only durable place to build the chart is
here.

Output is a single self-contained SVG committed to the repo, so the README shows
a static file: no SaaS in the request path, nothing to rate-limit, no runtime
dependency, and GitHub's camo proxy means readers never touch a third party.

Colours are GitHub's own accent palette, which is legible on both the light and
dark README themes -- so one file, rather than a <picture> with two.

    GITHUB_TOKEN=... python3 scripts/gen-star-history.py
    python3 scripts/gen-star-history.py --check    # CI: fail if stale/missing
"""
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

REPO = os.environ.get("STAR_REPO", "MotherofallVPNs/MoaV")
OUT = os.environ.get("STAR_OUT", "assets/star-history.svg")

W, H = 800, 260
PAD_L, PAD_R, PAD_T, PAD_B = 58, 18, 22, 34
LINE = "#d29922"     # MoaV accent orange
GRID = "#8b949e"     # GitHub mid grey: readable on both themes
TEXT = "#8b949e"


def fetch_stars():
    """Every starred_at, oldest first. Uses gh so auth matches the Actions token."""
    stamps, page = [], 1
    while True:
        out = subprocess.run(
            ["gh", "api", "-H", "Accept: application/vnd.github.star+json",
             f"repos/{REPO}/stargazers?per_page=100&page={page}"],
            capture_output=True, text=True,
        )
        if out.returncode != 0:
            # A 404 here is the restriction biting: the token is not an admin on
            # this repo. Say so plainly rather than emitting an empty chart.
            sys.stderr.write(out.stderr.strip()[:400] + "\n")
            raise SystemExit(
                "could not read stargazers — since 2026-06-30 this endpoint needs "
                "admin/collaborator access, so run this in the repo's own Actions"
            )
        batch = json.loads(out.stdout or "[]")
        if not batch:
            break
        stamps += [x["starred_at"] for x in batch if "starred_at" in x]
        if len(batch) < 100:
            break
        page += 1
    return sorted(stamps)


def build_series(stamps, max_points=90):
    """Cumulative (date, count), downsampled so the path stays small."""
    pts = [(datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc), i + 1)
           for i, s in enumerate(stamps)]
    if len(pts) <= max_points:
        return pts
    step = len(pts) / float(max_points)
    keep = [pts[int(i * step)] for i in range(max_points)]
    if keep[-1] != pts[-1]:
        keep.append(pts[-1])       # always land on the true current total
    return keep


def nice_ceil(n):
    """Round an axis max up to something a human would label."""
    if n <= 10:
        return 10
    for mult in (10, 25, 50, 100, 250, 500, 1000, 2500, 5000):
        if n <= mult * 4:
            return ((n + mult - 1) // mult) * mult
    return ((n + 9999) // 10000) * 10000


def render(series):
    if len(series) < 2:
        raise SystemExit("not enough stars to plot yet")
    t0, t1 = series[0][0], series[-1][0]
    span = max((t1 - t0).total_seconds(), 1.0)
    ymax = nice_ceil(series[-1][1])

    def x(dt):
        return PAD_L + (W - PAD_L - PAD_R) * ((dt - t0).total_seconds() / span)

    def y(v):
        return H - PAD_B - (H - PAD_T - PAD_B) * (v / ymax)

    pts = [(x(d), y(v)) for d, v in series]
    line = " ".join(f"{'M' if i == 0 else 'L'}{px:.1f},{py:.1f}"
                    for i, (px, py) in enumerate(pts))
    area = (line + f" L{pts[-1][0]:.1f},{y(0):.1f} L{pts[0][0]:.1f},{y(0):.1f} Z")

    # 4 horizontal gridlines + y labels
    grid = []
    for i in range(5):
        v = ymax * i / 4
        gy = y(v)
        grid.append(f'<line x1="{PAD_L}" y1="{gy:.1f}" x2="{W - PAD_R}" y2="{gy:.1f}" '
                    f'stroke="{GRID}" stroke-opacity="0.18" stroke-width="1"/>')
        grid.append(f'<text x="{PAD_L - 8}" y="{gy + 4:.1f}" text-anchor="end" '
                    f'font-size="11" fill="{TEXT}">{int(v)}</text>')

    # first / last date labels
    fmt = "%b %Y"
    xlabels = (
        f'<text x="{PAD_L}" y="{H - 12}" font-size="11" fill="{TEXT}">{t0.strftime(fmt)}</text>'
        f'<text x="{W - PAD_R}" y="{H - 12}" text-anchor="end" font-size="11" '
        f'fill="{TEXT}">{t1.strftime(fmt)}</text>'
    )
    total = series[-1][1]
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-label="MoaV star history: {total} stars">
  <title>MoaV star history — {total} stars as of {t1.strftime('%Y-%m-%d')}</title>
  <defs>
    <linearGradient id="fade" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="{LINE}" stop-opacity="0.28"/>
      <stop offset="100%" stop-color="{LINE}" stop-opacity="0.02"/>
    </linearGradient>
  </defs>
  <g font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif">
    {"".join(grid)}
    <path d="{area}" fill="url(#fade)"/>
    <path d="{line}" fill="none" stroke="{LINE}" stroke-width="2.5"
          stroke-linejoin="round" stroke-linecap="round"/>
    <circle cx="{pts[-1][0]:.1f}" cy="{pts[-1][1]:.1f}" r="3.5" fill="{LINE}"/>
    {xlabels}
    <text x="{PAD_L}" y="{PAD_T - 6}" font-size="12" font-weight="600"
          fill="{TEXT}">{total} stars</text>
  </g>
</svg>
'''


def main():
    check = "--check" in sys.argv
    if check:
        # Structural only: no network, so CI can gate the committed file.
        if not os.path.isfile(OUT):
            raise SystemExit(f"{OUT} is missing — run scripts/gen-star-history.py")
        body = open(OUT, encoding="utf-8").read()
        for needed in ("<svg", "star history", "</svg>"):
            if needed not in body:
                raise SystemExit(f"{OUT} does not look like a rendered chart (missing {needed!r})")
        print(f"gen-star-history: {OUT} present and well-formed")
        return

    svg = render(build_series(fetch_stars()))
    os.makedirs(os.path.dirname(OUT) or ".", exist_ok=True)
    old = open(OUT, encoding="utf-8").read() if os.path.isfile(OUT) else ""
    if old == svg:
        print(f"gen-star-history: {OUT} unchanged")
        return
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(svg)
    print(f"gen-star-history: wrote {OUT}")


if __name__ == "__main__":
    main()
