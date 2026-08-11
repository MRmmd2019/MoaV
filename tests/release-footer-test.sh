#!/bin/bash
# The release footer is generated, and must stay generated.
#
# It lived in a heredoc inside release.yml and drifted twice: the community links
# (Telegram, X, issues, website) existed only because someone pasted them into the
# v2.0.0 body by hand, the donation/support page was never linked, and the docs
# list still named six pages after the rewrite shipped fourteen more. Nothing
# noticed, because a workflow heredoc has no reader.
#
# Offline structural checks only -- the live URL check is
# `scripts/render-release-footer.sh --check`, a separate CI step, so this suite
# stays runnable without network.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gen="$ROOT/scripts/render-release-footer.sh"
wf="$ROOT/.github/workflows/release.yml"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "release footer generator"

[[ -x "$gen" ]] && ok "generator exists and is executable" || bad "generator missing or not executable"

out="$(bash "$gen" 2>/dev/null)"
[[ -n "$out" ]] && ok "generator produces output" || bad "generator produced nothing"

# --- release.yml must call it, not inline the footer -----------------------
grep -q 'render-release-footer.sh' "$wf" \
    && ok "release.yml calls the generator" \
    || bad "release.yml does not call the generator"

if grep -qE "^\s+- \[Setup Guide\]\(https://moav.sh/docs/SETUP\)" "$wf"; then
    bad "release.yml still inlines the docs list — the drift is back"
else
    ok "release.yml no longer inlines the docs list"
fi

# --- the append-guard sentinel must survive ---------------------------------
# release.yml skips appending when the body already contains "## Quick Install",
# so a hand-edited release body is not clobbered. Renaming that heading in the
# generator would silently double-append the footer on every re-run.
grep -q '## Quick Install' <<<"$out" \
    && ok "footer keeps the '## Quick Install' append-guard sentinel" \
    || bad "sentinel gone — release.yml would append the footer twice"

# --- every category the card called out ------------------------------------
for want in "Quick Start" "Client Setup" "CLI Reference" "Troubleshooting" \
            "Supported Protocols" "Threat Model" "Support MoaV" "Translating the Docs"; do
    grep -qF "$want" <<<"$out" && ok "links $want" || bad "missing docs link: $want"
done

for want in "t.me/motherofallvpns" "x.com/motherofallvpns" "/issues" "llms.txt"; do
    grep -qF "$want" <<<"$out" && ok "links $want" || bad "missing link: $want"
done

# Quick Start must come before the Setup Guide: a release note is read by someone
# deciding whether to install, not by someone looking up an option.
qs=$(grep -n 'docs/quick-start' <<<"$out" | head -1 | cut -d: -f1)
sg=$(grep -n 'docs/SETUP' <<<"$out" | head -1 | cut -d: -f1)
if [[ -n "$qs" && -n "$sg" && "$qs" -lt "$sg" ]]; then
    ok "Quick Start is listed before the Setup Guide"
else
    bad "Quick Start must precede the Setup Guide (got qs=$qs sg=$sg)"
fi

# --- community URLs must come from lib/common.sh ----------------------------
# Same assertion tests/cli-surface-test.sh makes about the CLI footer: if the
# generator hardcodes them, the release notes and `moav help` can disagree.
body="$(sed 's/[[:space:]]*#.*$//' "$gen")"
if grep -qE 'https://(t\.me|x\.com)/motherofallvpns' <<<"$body"; then
    bad "generator hardcodes a community URL instead of using MOAV_URL_*"
else
    ok "community URLs come from the MOAV_URL_* variables"
fi

for v in MOAV_URL_SITE MOAV_URL_DOCS MOAV_URL_TG MOAV_URL_X MOAV_URL_GH; do
    grep -q "$v" <<<"$body" && ok "uses \$$v" || bad "does not use \$$v"
done

# --- prerelease variant ------------------------------------------------------
pre="$(bash "$gen" --pre 2>/dev/null)"
grep -q 'latest \*\*stable\*\*' <<<"$pre" \
    && ok "--pre emits the stable-install caveat" \
    || bad "--pre lost the prerelease caveat"
grep -q 'latest \*\*stable\*\*' <<<"$out" \
    && bad "stable release wrongly carries the prerelease caveat" \
    || ok "stable release has no prerelease caveat"

# --- no unrendered placeholders ---------------------------------------------
if grep -qE '\$\{?[A-Z_]+\}?' <<<"$out"; then
    bad "footer contains an unexpanded variable: $(grep -oE '\$\{?[A-Z_]+\}?' <<<"$out" | head -1)"
else
    ok "no unexpanded variables in the rendered footer"
fi

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
