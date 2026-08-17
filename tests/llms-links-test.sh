#!/bin/bash
# Regression test: every link in llms.txt must be absolute.
#
# llms.txt is served at https://moav.sh/llms.txt but written in the repo, so a
# relative link like [AGENTS.md](AGENTS.md) resolves against the SITE --
# https://moav.sh/AGENTS.md, which 404s. It only ever worked when read inside
# the GitHub repo. An agent handed the URL follows the link and gets nothing,
# with no error to notice; a community member spotted it before we did.
#
# Offline by default (structure only). LLMS_CHECK_URLS=1 also fetches each one;
# CI runs that as a separate networked step.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
f="$ROOT/llms.txt"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "llms.txt link hygiene"

[ -f "$f" ] || { echo "  llms.txt not found"; exit 1; }

# --- no relative markdown links ---------------------------------------------
# Anchors (#section) are fine — they stay within the served file.
rel=$(grep -oE '\]\([^)]+\)' "$f" | sed 's/^](//; s/)$//' \
        | grep -vE '^(https?://|#)' || true)
if [ -z "$rel" ]; then
    ok "no relative links (all absolute or in-page anchors)"
else
    bad "relative link(s) — these resolve against moav.sh and 404: $(printf '%s' "$rel" | tr '\n' ' ')"
fi

# --- repo files must point at GitHub, not the docs site ----------------------
# AGENTS.md and friends are not published on moav.sh; linking them there is the
# same bug in a different shape.
for repo_file in AGENTS.md CONTRIBUTING.md CHANGELOG.md; do
    line=$(grep -F "$repo_file]" "$f" | head -1 || true)
    [ -n "$line" ] || continue
    if printf '%s' "$line" | grep -q 'moav\.sh'; then
        bad "$repo_file is linked on moav.sh, but it is only published in the repo"
    else
        ok "$repo_file points at the repo"
    fi
done

# --- docs pages must point at the site, not at GitHub ------------------------
# The inverse: a published docs page should link to its canonical URL.
docs_on_gh=$(grep -oE 'https://[a-z.]*github[^)]*/docs/(quick-start|SETUP|CLI|protocols|architecture)\.md' "$f" || true)
[ -z "$docs_on_gh" ] \
    && ok "published docs pages link to moav.sh, not GitHub" \
    || bad "docs page linked to GitHub instead of its moav.sh URL: $docs_on_gh"

# --- optional network check --------------------------------------------------
if [ "${LLMS_CHECK_URLS:-0}" = "1" ]; then
    # Only markdown link TARGETS. A bare grep for https:// also picks up prose
    # placeholders like `https://<server>:9443`, which are not links to fetch.
    urls=()
    while IFS= read -r u; do [ -n "$u" ] && urls+=("$u"); done < <(
        grep -oE '\]\(https://[^)]+\)' "$f" | sed 's/^](//; s/)$//' | sed 's/[.,]$//' | sort -u)
    for u in "${urls[@]}"; do
        code=000
        for _a in 1 2 3; do
            code=$(curl -sS -o /dev/null -w '%{http_code}' -L --max-time 20 -A 'moav-ci-linkcheck' "$u" 2>/dev/null || echo 000)
            [ "$code" = "200" ] && break
            sleep $((_a * 2))
        done
        if [ "$code" = "200" ]; then
            ok "resolves: $u"
        elif printf '%s' "$u" | grep -qE '^https://(github\.com|raw\.githubusercontent\.com|objects\.githubusercontent\.com|x\.com|t\.me)/'; then
            # GitHub and social hosts rate-limit unauthenticated CI requests and
            # go 000/403/404/429/503 under load or a GitHub incident. Warn, don't
            # fail the release; moav.sh docs links (the ones that rot) stay strict.
            printf '  warn  %s -> HTTP %s (rate-limit/incident on a GitHub/social host, not verified)\n' "$u" "$code"
        else
            bad "$u -> HTTP $code"
        fi
    done
fi

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
