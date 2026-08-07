#!/bin/bash
# Regression test: user UUID capture must never yield two UUIDs.
#
# `moav user add` generated the UUID as:
#   USER_UUID=$(compose_timeout exec -T sing-box sing-box generate uuid \
#              2>/dev/null || uuidgen | tr ...)
# When the box was contended the `docker compose exec` emitted a UUID and THEN
# the timeout wrapper killed it (non-zero), so the `|| uuidgen` fallback ran too
# and appended a SECOND UUID. USER_UUID became two lines, which:
#   - corrupts credentials.env — the bare second UUID is sourced as a command
#     ("<uuid>: command not found"), failing bootstrap and regenerate-users;
#   - crash-loops xray/sing-box — the two-line UUID is rejected ("invalid UUID").
# The fix takes the FIRST uuid-shaped token and validates it, falling back to
# uuidgen only when nothing valid was produced.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
f="$ROOT/scripts/singbox-user-add.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "user UUID capture tests"

UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

# --- static: the fragile 'exec ... || uuidgen' one-liner must be gone ---------
if grep -qE 'generate uuid[^|]*\|\| *uuidgen' "$f"; then
    bad "still has 'exec generate uuid || uuidgen' — a timed-out exec + fallback double-captures"
else
    ok "no 'exec generate uuid || uuidgen' double-capture one-liner"
fi
# and the capture must validate the UUID shape before trusting it
if grep -qE '\[\[ ! "\$USER_UUID" =~' "$f" || grep -qE 'USER_UUID.*=~.*36' "$f"; then
    ok "USER_UUID is validated before use"
else
    bad "USER_UUID is not validated — a malformed value would propagate to configs"
fi

# --- functional: the sanitizer collapses any output to one valid UUID ---------
# Mirror the exact fix pipeline and feed it the failure inputs.
sanitize() {
    local raw="$1" u
    u=$(printf '%s' "$raw" | grep -oiE "$UUID_RE" | head -1)
    if [[ ! "$u" =~ ^[0-9a-fA-F-]{36}$ ]]; then
        u=$(uuidgen | tr '[:upper:]' '[:lower:]')
    fi
    printf '%s' "$u"
}
one_line() { [[ "$(printf '%s' "$1" | wc -l)" -eq 0 ]] && [[ -n "$1" ]]; }

# two UUIDs (the bug) -> exactly one, and it's the first
two=$'ea901364-3597-4598-8628-161a381b63cf\n7f90d9d8-83a5-4e0d-b963-a1a8d268ea48'
r=$(sanitize "$two")
if one_line "$r" && [[ "$r" == "ea901364-3597-4598-8628-161a381b63cf" ]]; then
    ok "two-line output collapses to the first single UUID"
else
    bad "two-line output not collapsed cleanly (got: $r)"
fi

# empty output -> a freshly generated valid UUID
r=$(sanitize "")
if one_line "$r" && [[ "$r" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    ok "empty output falls back to a valid single UUID"
else
    bad "empty output did not fall back to a valid UUID (got: $r)"
fi

# already-clean single UUID -> unchanged
r=$(sanitize "2b2a0db8-b379-4ae6-a524-c6d37f78119b")
if [[ "$r" == "2b2a0db8-b379-4ae6-a524-c6d37f78119b" ]]; then
    ok "a clean single UUID passes through unchanged"
else
    bad "a clean single UUID was altered (got: $r)"
fi

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
