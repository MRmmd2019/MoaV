#!/usr/bin/env bash
# Render the donation block in README.md (and README-fa.md) from
# .github/FUNDING.yml, so the addresses live in exactly one place.
#
# FUNDING.yml is already the canonical list -- GitHub reads `github:` and
# `buy_me_a_coffee:` for the Sponsor button and ignores the crypto keys, which
# is fine because those are ours. Copying addresses into a README by hand is how
# the sing-box version ended up pinned in nine places, and an address is the one
# thing that must never be wrong.
#
#   scripts/render-funding.sh            # rewrite the block in place
#   scripts/render-funding.sh --check    # CI: fail if the block is stale
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FUNDING="$ROOT/.github/FUNDING.yml"
START="<!-- FUNDING:START -->"
END="<!-- FUNDING:END -->"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

[[ -f "$FUNDING" ]] || { echo "render-funding: $FUNDING not found" >&2; exit 1; }

render() {
    python3 - "$FUNDING" "$1" <<'PY'
import re, sys

funding, lang = sys.argv[1], sys.argv[2]

# Deliberately not a YAML parser: this is a flat key/value list and depending on
# PyYAML would add a build dependency for a dozen lines.
platforms = {
    "github":          ("GitHub Sponsors", "https://github.com/sponsors/{v}"),
    "buy_me_a_coffee": ("Buy Me a Coffee", "https://buymeacoffee.com/{v}"),
    "open_collective": ("Open Collective", "https://opencollective.com/{v}"),
    "liberapay":       ("Liberapay",       "https://liberapay.com/{v}"),
    "ko_fi":           ("Ko-fi",           "https://ko-fi.com/{v}"),
}
coins = {
    "BTC": "Bitcoin", "ETH": "Ethereum", "ZEC": "Zcash", "XMR": "Monero",
    "LTC": "Litecoin", "TRON": "Tron", "SOL": "Solana",
    "LN": "Lightning", "LIGHTNING": "Lightning",
    "LN_ADDRESS": "Lightning Address",
}
# Keys whose pretty name already says everything -- no "(KEY)" suffix, which
# would render as the useless "Lightning Address (LN_ADDRESS)".
NO_SUFFIX = {"LN", "LIGHTNING", "LN_ADDRESS"}
# ETH is one address across every EVM chain; Tron is NOT -- TRX/TRC-20 use a
# base58 address and anything sent to the 0x one is unrecoverable.
notes_en = {
    "ETH": "same address on every EVM chain (Arbitrum, Optimism, Base, Gnosis…) and any ERC20 (USDC, USDT, DAI…)",
    "TRON": "TRX and TRC-20 only — not interchangeable with the EVM address",
    "LN": "BOLT12 offer — reusable, paste into a wallet that supports offers",
    "LN_ADDRESS": "easier option: works like an email address in most Lightning wallets",
}
notes_fa = {
    "ETH": "همین نشانی روی همهٔ زنجیره‌های EVM کار می‌کند و برای هر توکن ERC-20",
    "TRON": "فقط TRX و TRC-20 — با نشانی EVM بالا یکی نیست",
    "LN": "پیشنهاد BOLT12 — قابل استفادهٔ چندباره، در کیف‌پولی که offer را پشتیبانی می‌کند",
    "LN_ADDRESS": "گزینهٔ ساده‌تر: در بیشتر کیف‌پول‌های لایتنینگ مثل نشانی ایمیل کار می‌کند",
}
head = {"en": ("Platform", "Link", "Coin", "Address"),
        "fa": ("پلتفرم", "لینک", "ارز", "نشانی")}[lang]
notes = notes_en if lang == "en" else notes_fa

plat, crypto, footnotes = [], [], []
for line in open(funding, encoding="utf-8"):
    line = line.split("#", 1)[0].strip()
    m = re.match(r"^([A-Za-z_]+)\s*:\s*(.+)$", line)
    if not m:
        continue
    key, val = m.group(1), m.group(2).strip().strip("[]").strip().strip("'\"")
    if not val:
        continue
    if key in platforms:
        name, url = platforms[key]
        full = url.format(v=val)
        plat.append(f"| **{name}** | [{full.split('//')[1]}]({full}) |")
    else:
        nice = coins.get(key.upper(), key)
        label = nice if key.upper() in NO_SUFFIX or nice.upper() == key.upper() \
                else f"{nice} ({key.upper()})"
        note = notes.get(key.upper())
        marker = ""
        if note:
            # Superscript numerals, not asterisks: a line starting with "*"
            # renders as a bullet and "**" as broken bold.
            sup = "¹²³⁴⁵⁶⁷⁸⁹"[len(footnotes)]
            marker = " " + sup
            footnotes.append(f"{sup} **{label}** — {note}")
        crypto.append(f"| **{label}**{marker} | `{val}` |")

out = []
if plat:
    out += [f"| {head[0]} | {head[1]} |", "|---|---|", *plat, ""]
if crypto:
    out += [f"| {head[2]} | {head[3]} |", "|---|---|", *crypto]
    # Notes live under the table: inline they wrap inside a narrow first column
    # and blow the row height up to a dozen lines on GitHub.
    if footnotes:
        for fn in footnotes:
            out += ["", fn]
print("\n".join(out).rstrip())
PY
}

status=0
for f in README.md README-fa.md; do
    path="$ROOT/$f"
    [[ -f "$path" ]] || continue
    grep -q "$START" "$path" || continue    # file has no block yet; skip silently

    lang=en
    [[ "$f" == *-fa.md ]] && lang=fa
    block=$(render "$lang")

    new=$(python3 - "$path" "$START" "$END" "$block" <<'PY'
import sys
path, start, end, block = sys.argv[1:5]
s = open(path, encoding="utf-8").read()
a = s.index(start) + len(start)
b = s.index(end)
sys.stdout.write(s[:a] + "\n" + block + "\n" + s[b:])
PY
)
    if [[ "$CHECK" == "1" ]]; then
        if [[ "$new" != "$(cat "$path")" ]]; then
            echo "render-funding: $f is out of date — run scripts/render-funding.sh" >&2
            status=1
        else
            echo "render-funding: $f up to date"
        fi
    else
        printf '%s\n' "$new" > "$path"
        echo "render-funding: refreshed the donation block in $f"
    fi
done
exit "$status"
