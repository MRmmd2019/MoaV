#!/bin/bash
# Regression test: the crypto values in .github/FUNDING.yml must stay quoted.
#
# ETH's address is `0x...`, which is valid YAML hex -- unquoted, any YAML parser
# returns the integer 1032266289302213910388939894421575686213359504098 and the
# address is silently gone. Nothing consumes this file with PyYAML today (both
# generators regex-parse it, deliberately), but a future test, doctor check or
# site script reaching for safe_load would publish a number as a donation
# address, and nobody proof-reads a long hex string.
#
# The quotes cost nothing: both generators strip them.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FUNDING="$ROOT/.github/FUNDING.yml"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "FUNDING.yml: address values survive a YAML parser"

# --- every crypto value is quoted ------------------------------------------
# Platform keys are lowercase (github, buy_me_a_coffee); tickers are not.
unquoted=$(grep -E '^[A-Z][A-Za-z_]*:' "$FUNDING" | grep -vE ':[[:space:]]*"' || true)
if [ -z "$unquoted" ]; then
    ok "all address values are quoted"
else
    bad "unquoted address value(s): ${unquoted%%:*} -- a 0x value would load as an int"
fi

# --- and a parser really does hand back strings -----------------------------
if python3 -c 'import yaml' 2>/dev/null; then
    types=$(python3 - "$FUNDING" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
print(" ".join(k for k, v in d.items() if not isinstance(v, (str, list))))
PY
)
    [ -z "$types" ] && ok "yaml.safe_load returns a string for every value" \
                    || bad "yaml.safe_load mangles: $types"
else
    echo "  note  PyYAML not installed; skipped the parser check"
fi

# --- the negative control: unquoting ETH must trip the check above ----------
# Without this, a rewritten grep that matches nothing would still 'pass'.
tmp=$(mktemp)
sed 's/^ETH: "\(.*\)"$/ETH: \1/' "$FUNDING" > "$tmp"
if grep -qE '^ETH:[[:space:]]*0x' "$tmp"; then
    caught=$(grep -E '^[A-Z][A-Za-z_]*:' "$tmp" | grep -vE ':[[:space:]]*"' || true)
    case "$caught" in
        *ETH*) ok "the quoting check catches an unquoted ETH line" ;;
        *)     bad "an unquoted ETH line slipped past the check -- the guard is vacuous" ;;
    esac
else
    bad "could not build the negative control (ETH line format changed?)"
fi
rm -f "$tmp"

# --- generators must strip the quotes, not print them -----------------------
rendered=$(sed -n '/FUNDING:START/,/FUNDING:END/p' "$ROOT/README.md")
if printf '%s' "$rendered" | grep -q '"0x'; then
    bad "the README block contains a quoted address -- render-funding.sh stopped stripping quotes"
else
    ok "the rendered README block carries bare addresses"
fi

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
