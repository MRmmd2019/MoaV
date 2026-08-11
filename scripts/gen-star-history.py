#!/usr/bin/env python3
"""Render assets/star-history.svg from this repo's own stargazer timestamps.

Why we generate it instead of embedding star-history.com: on 2026-06-30 GitHub
restricted /repos/{owner}/{repo}/stargazers to a repo's own admins and
collaborators, because the data was being harvested for spam. The hosted embed
still answers HTTP 200 for any repo, but the image it returns is now a notice
reading "GitHub restricted access to star data", not a chart. Their token
workaround does work, but it means handing a third party a credential that reads
this repo, embedded in a public README, and they describe it as temporary.

This repo's own GITHUB_TOKEN *is* admin here, so the durable place to build the
chart is here. Output is a single committed SVG: no credential, no vendor, no
request leaving GitHub, and immune to the next policy change.

The layout deliberately mirrors star-history.com's -- 800x533 white card, "Star
History" title, "Date" axis, abbreviated star counts, repo legend -- because that
chart is what readers recognise. The one thing not copied is their xkcd webfont,
which is 58 KB of base64 and would be most of the file; FONT below is a
hand-drawn stack that falls back cleanly.

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

W, H = 800, 533
PAD_L, PAD_R, PAD_T, PAD_B = 84, 28, 58, 74
BG = "#ffffff"
INK = "#1f2328"      # axes + title, on white
MUTED = "#57606a"    # tick labels
GRID = "#d0d7de"
LINE = "#d29922"     # MoaV accent orange
# Hand-drawn feel without embedding a webfont. Resolves per viewer, so the last
# entry matters: layout stays right even where none of the others exist.
FONT = ("'Comic Sans MS','Chalkboard SE','Marker Felt','Segoe Print',"
        "'Bradley Hand',cursive,sans-serif")


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


def build_series(stamps, max_points=110):
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
    if n <= 10:
        return 10
    for mult in (10, 25, 50, 100, 250, 500, 1000, 2500, 5000):
        if n <= mult * 4:
            return ((n + mult - 1) // mult) * mult
    return ((n + 9999) // 10000) * 10000


def kfmt(v):
    """1200 -> 1.2K, 2000 -> 2K, 340 -> 340. Matches star-history's tick style."""
    v = int(v)
    if v < 1000:
        return str(v)
    s = f"{v / 1000:.1f}".rstrip("0").rstrip(".")
    return f"{s}K"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def render(series):
    if len(series) < 2:
        raise SystemExit("not enough stars to plot yet")
    t0, t1 = series[0][0], series[-1][0]
    span = max((t1 - t0).total_seconds(), 1.0)
    ymax = nice_ceil(series[-1][1])
    total = series[-1][1]

    def x(dt):
        return PAD_L + (W - PAD_L - PAD_R) * ((dt - t0).total_seconds() / span)

    def y(v):
        return H - PAD_B - (H - PAD_T - PAD_B) * (v / ymax)

    pts = [(x(d), y(v)) for d, v in series]
    line = " ".join(f"{'M' if i == 0 else 'L'}{px:.1f},{py:.1f}"
                    for i, (px, py) in enumerate(pts))
    area = line + f" L{pts[-1][0]:.1f},{y(0):.1f} L{pts[0][0]:.1f},{y(0):.1f} Z"

    # Y gridlines + abbreviated counts, like theirs.
    grid = []
    for i in range(5):
        v = ymax * i / 4
        gy = y(v)
        grid.append(f'<line x1="{PAD_L}" y1="{gy:.1f}" x2="{W - PAD_R}" y2="{gy:.1f}" '
                    f'stroke="{GRID}" stroke-width="1"/>')
        grid.append(f'<text x="{PAD_L - 12}" y="{gy + 5:.1f}" text-anchor="end" '
                    f'font-size="14" fill="{MUTED}">{kfmt(v)}</text>')

    # X ticks: years for a long history, month+year for a short one — the same
    # judgement star-history makes (their sample spans a decade and shows years).
    years = span / (365.25 * 86400)
    fmt = "%Y" if years >= 2.5 else "%b %Y"
    nticks = 6 if years >= 2.5 else 5
    xt = []
    seen = set()
    for i in range(nticks):
        frac = i / float(nticks - 1)
        dt = datetime.fromtimestamp(t0.timestamp() + span * frac, tz=timezone.utc)
        lab = dt.strftime(fmt)
        if lab in seen:                    # avoid repeating "Aug 2026" twice
            continue
        seen.add(lab)
        tx = x(dt)
        xt.append(f'<line x1="{tx:.1f}" y1="{y(0):.1f}" x2="{tx:.1f}" y2="{y(0) + 6:.1f}" '
                  f'stroke="{MUTED}" stroke-width="1.5"/>')
        xt.append(f'<text x="{tx:.1f}" y="{y(0) + 26:.1f}" text-anchor="middle" '
                  f'font-size="14" fill="{MUTED}">{lab}</text>')

    legend_y = PAD_T + 14
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-label="Star history for {esc(REPO)}: {total} stars">
  <title>Star History — {esc(REPO)}, {total} stars as of {t1.strftime('%Y-%m-%d')}</title>
  <defs>
    <linearGradient id="fade" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="{LINE}" stop-opacity="0.22"/>
      <stop offset="100%" stop-color="{LINE}" stop-opacity="0.02"/>
    </linearGradient>
  </defs>
  <rect width="{W}" height="{H}" rx="8" fill="{BG}"/>
  <g font-family="{FONT}">
    <text x="{W / 2:.0f}" y="34" text-anchor="middle" font-size="22" fill="{INK}">Star History</text>
    {"".join(grid)}
    <path d="{area}" fill="url(#fade)"/>
    <path d="{line}" fill="none" stroke="{LINE}" stroke-width="3"
          stroke-linejoin="round" stroke-linecap="round"/>
    <circle cx="{pts[-1][0]:.1f}" cy="{pts[-1][1]:.1f}" r="4.5" fill="{LINE}"/>
    <line x1="{PAD_L}" y1="{PAD_T}" x2="{PAD_L}" y2="{y(0):.1f}" stroke="{INK}" stroke-width="2"/>
    <line x1="{PAD_L}" y1="{y(0):.1f}" x2="{W - PAD_R}" y2="{y(0):.1f}" stroke="{INK}" stroke-width="2"/>
    {"".join(xt)}
    <text x="{W / 2:.0f}" y="{H - 18}" text-anchor="middle" font-size="15" fill="{INK}">Date</text>
    <text transform="translate(26,{H / 2:.0f}) rotate(-90)" text-anchor="middle"
          font-size="15" fill="{INK}">GitHub Stars</text>
    <circle cx="{PAD_L + 14}" cy="{legend_y - 4}" r="5" fill="{LINE}"/>
    <text x="{PAD_L + 26}" y="{legend_y}" font-size="15" fill="{INK}">{esc(REPO)}</text>
  </g>
</svg>
'''


def main():
    if "--check" in sys.argv:
        # Structural only: no network, so CI can gate the committed file.
        if not os.path.isfile(OUT):
            raise SystemExit(f"{OUT} is missing — run scripts/gen-star-history.py")
        body = open(OUT, encoding="utf-8").read()
        for needed in ("<svg", "Star History", "GitHub Stars", "</svg>"):
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
