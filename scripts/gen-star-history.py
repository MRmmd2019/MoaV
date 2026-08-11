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

# Comma-separated. A repo we cannot read is skipped with a warning rather than
# failing the run -- see fetch_stars().
REPOS = [r.strip() for r in os.environ.get(
    "STAR_REPOS", "MotherofallVPNs/MoaV,MotherofallVPNs/moav-client").split(",") if r.strip()]
OUT = os.environ.get("STAR_OUT", "assets/star-history.svg")
LOGO = os.environ.get("STAR_LOGO", "branding/favicon-56.png")

W, H = 800, 533
PAD_L, PAD_R, PAD_T, PAD_B = 84, 28, 58, 74
BG = "#ffffff"
INK = "#1f2328"      # axes + title, on white
MUTED = "#57606a"    # tick labels
GRID = "#d0d7de"
# From the logo's own gradient (#00e8fe cyan -> #0097f9 blue), so the chart and
# the watermark belong to each other.
SERIES = ["#00d8fb", "#0969da"]
# Hand-drawn feel without embedding a webfont. Resolves per viewer, so the last
# entry matters: layout stays right even where none of the others exist.
FONT = ("'Comic Sans MS','Chalkboard SE','Marker Felt','Segoe Print',"
        "'Bradley Hand',cursive,sans-serif")


def fetch_stars(repo):
    """Every starred_at for one repo, oldest first. None if we cannot read it.

    A repo-scoped GITHUB_TOKEN is admin only on its OWN repo, so a second repo
    needs a token with access to both. Rather than fail the whole run when that
    secret is absent, skip the unreadable repo and chart the rest -- a chart
    missing one line beats no chart at all.
    """
    stamps, page = [], 1
    while True:
        out = subprocess.run(
            ["gh", "api", "-H", "Accept: application/vnd.github.star+json",
             f"repos/{repo}/stargazers?per_page=100&page={page}"],
            capture_output=True, text=True,
        )
        if out.returncode != 0:
            err = out.stderr.strip()[:300]
            sys.stderr.write(f"skipping {repo}: {err}\n")
            sys.stderr.write(
                "  (since 2026-06-30 stargazers needs admin/collaborator access; "
                "set STAR_TOKEN to a token that can read every repo listed)\n")
            return None
        batch = json.loads(out.stdout or "[]")
        if not batch:
            break
        stamps += [x["starred_at"] for x in batch if "starred_at" in x]
        if len(batch) < 100:
            break
        page += 1
    return sorted(stamps)


def logo_data_uri():
    """The watermark, inlined so the SVG stays self-contained."""
    try:
        import base64
        with open(LOGO, "rb") as f:
            return "data:image/png;base64," + base64.b64encode(f.read()).decode("ascii")
    except OSError:
        return ""


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


def render(datasets):
    """datasets: list of (repo, [(datetime, cumulative_count), ...]) in draw order."""
    datasets = [(r, pts) for r, pts in datasets if len(pts) >= 2]
    if not datasets:
        raise SystemExit("no repo had enough stars to plot")

    t0 = min(p[0][0] for _, p in datasets)
    t1 = max(p[-1][0] for _, p in datasets)
    span = max((t1 - t0).total_seconds(), 1.0)
    ymax = nice_ceil(max(p[-1][1] for _, p in datasets))

    def x(dt):
        return PAD_L + (W - PAD_L - PAD_R) * ((dt - t0).total_seconds() / span)

    def y(v):
        return H - PAD_B - (H - PAD_T - PAD_B) * (v / ymax)

    # Y gridlines + abbreviated counts, like theirs.
    grid = []
    for i in range(5):
        v = ymax * i / 4
        gy = y(v)
        grid.append(f'<line x1="{PAD_L}" y1="{gy:.1f}" x2="{W - PAD_R}" y2="{gy:.1f}" '
                    f'stroke="{GRID}" stroke-width="1"/>')
        grid.append(f'<text x="{PAD_L - 12}" y="{gy + 5:.1f}" text-anchor="end" '
                    f'font-size="14" fill="{MUTED}">{kfmt(v)}</text>')

    # X ticks: years for a long history, month+year for a short one -- the same
    # judgement star-history makes (their sample spans a decade and shows years).
    years = span / (365.25 * 86400)
    fmt = "%Y" if years >= 2.5 else "%b %Y"
    nticks = 6 if years >= 2.5 else 5
    xt, seen = [], set()
    for i in range(nticks):
        dt = datetime.fromtimestamp(t0.timestamp() + span * (i / float(nticks - 1)),
                                    tz=timezone.utc)
        lab = dt.strftime(fmt)
        if lab in seen:
            continue
        seen.add(lab)
        tx = x(dt)
        xt.append(f'<line x1="{tx:.1f}" y1="{y(0):.1f}" x2="{tx:.1f}" y2="{y(0) + 6:.1f}" '
                  f'stroke="{MUTED}" stroke-width="1.5"/>')
        xt.append(f'<text x="{tx:.1f}" y="{y(0) + 26:.1f}" text-anchor="middle" '
                  f'font-size="14" fill="{MUTED}">{lab}</text>')

    # One line + fade per repo, drawn largest-first so a small series stays visible.
    defs, paths, legend = [], [], []
    for idx, (repo, pts) in enumerate(datasets):
        colour = SERIES[idx % len(SERIES)]
        xy = [(x(d), y(v)) for d, v in pts]
        line = " ".join(f"{'M' if i == 0 else 'L'}{px:.1f},{py:.1f}"
                        for i, (px, py) in enumerate(xy))
        area = line + f" L{xy[-1][0]:.1f},{y(0):.1f} L{xy[0][0]:.1f},{y(0):.1f} Z"
        defs.append(f'<linearGradient id="fade{idx}" x1="0" y1="0" x2="0" y2="1">'
                    f'<stop offset="0%" stop-color="{colour}" stop-opacity="0.22"/>'
                    f'<stop offset="100%" stop-color="{colour}" stop-opacity="0.02"/></linearGradient>')
        paths.append(f'<path d="{area}" fill="url(#fade{idx})"/>')
        paths.append(f'<path d="{line}" fill="none" stroke="{colour}" stroke-width="3" '
                     f'stroke-linejoin="round" stroke-linecap="round"/>')
        paths.append(f'<circle cx="{xy[-1][0]:.1f}" cy="{xy[-1][1]:.1f}" r="4.5" fill="{colour}"/>')
        ly = PAD_T + 14 + idx * 22
        legend.append(f'<circle cx="{PAD_L + 14}" cy="{ly - 4}" r="5" fill="{colour}"/>'
                      f'<text x="{PAD_L + 26}" y="{ly}" font-size="15" fill="{INK}">'
                      f'{esc(repo)} <tspan fill="{MUTED}">({pts[-1][1]})</tspan></text>')

    # Watermark: bottom-right INSIDE the card but clear of the plot frame, so it
    # never sits on an axis or over the data.
    logo = logo_data_uri()
    mark = ""
    if logo:
        size = 30
        mark = (f'<image href="{logo}" x="{W - PAD_R - size}" y="{H - 46}" '
                f'width="{size}" height="{size}" opacity="0.85"/>')

    summary = ", ".join(f"{r} {p[-1][1]}" for r, p in datasets)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-label="Star history: {esc(summary)}">
  <title>Star History — {esc(summary)} as of {t1.strftime('%Y-%m-%d')}</title>
  <defs>{"".join(defs)}</defs>
  <rect width="{W}" height="{H}" rx="8" fill="{BG}"/>
  <g font-family="{FONT}">
    <text x="{W / 2:.0f}" y="34" text-anchor="middle" font-size="22" fill="{INK}">Star History</text>
    {"".join(grid)}
    {"".join(paths)}
    <line x1="{PAD_L}" y1="{PAD_T}" x2="{PAD_L}" y2="{y(0):.1f}" stroke="{INK}" stroke-width="2"/>
    <line x1="{PAD_L}" y1="{y(0):.1f}" x2="{W - PAD_R}" y2="{y(0):.1f}" stroke="{INK}" stroke-width="2"/>
    {"".join(xt)}
    <text x="{W / 2:.0f}" y="{H - 18}" text-anchor="middle" font-size="15" fill="{INK}">Date</text>
    <text transform="translate(26,{H / 2:.0f}) rotate(-90)" text-anchor="middle"
          font-size="15" fill="{INK}">GitHub Stars</text>
    {"".join(legend)}
    {mark}
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

    datasets = []
    for repo in REPOS:
        stamps = fetch_stars(repo)
        if stamps:
            datasets.append((repo, build_series(stamps)))
    if not datasets:
        raise SystemExit("no readable repo in STAR_REPOS")
    # Largest total first: its fade is drawn under the smaller one's line.
    datasets.sort(key=lambda d: d[1][-1][1], reverse=True)
    svg = render(datasets)
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
