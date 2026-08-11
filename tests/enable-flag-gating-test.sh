#!/bin/bash
# Regression test: `moav user add` must not generate configs for a protocol the
# operator disabled.
#
# Reported by a user: bundles contained protocols they never enabled. Cause was
# an asymmetry between the two add paths. generate-user.sh (the container /
# bootstrap path) gated Reality, Trojan, Hysteria2 and TrustTunnel on their
# ENABLE_* flags; singbox-user-add.sh (the HOST path, what `moav user add` runs)
# gated only SS, AnyTLS and XHTTP. So bootstrap-created users were correct while
# every later user got share links for inbounds the operator had turned off.
#
# TrustTunnel had a second cause: it was gated on configs/trusttunnel/
# credentials.toml existing, and that file survives disabling the protocol.
#
# Static test -- it asserts each generation site sits behind its flag. The live
# both-directions check runs in e2e (disabled protocols absent, enabled present).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host="$ROOT/scripts/singbox-user-add.sh"
cont="$ROOT/scripts/generate-user.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "ENABLE_* gating in the user-add paths"

# Does $2 (an artifact write) sit inside a block guarded by $1 (its flag)?
# Walks the file tracking the nearest enclosing `if` that mentions the flag.
gated() {  # <flag> <artifact-write-substring> <file>
    python3 - "$1" "$2" "$3" <<'PY'
import sys, re
flag, needle, path = sys.argv[1], sys.argv[2], sys.argv[3]
depth, guard = 0, []          # guard[i] = True if the if at depth i tests flag
for line in open(path):
    s = line.strip()
    if re.match(r'^(if|elif)\b', s):
        if re.match(r'^if\b', s):
            guard.append(flag in s)
            depth += 1
        elif guard:
            guard[-1] = guard[-1] or (flag in s)
    elif s.startswith('fi') and guard:
        guard.pop(); depth -= 1
    if needle in s and not s.startswith('#'):
        sys.exit(0 if any(guard) else 1)
sys.exit(2)   # needle not found
PY
}

check() {  # <label> <flag> <needle> <file>
    local label="$1" flag="$2" needle="$3" file="$4"
    gated "$flag" "$needle" "$file"
    case "$?" in
        0) ok   "$label gated on $flag" ;;
        1) bad  "$label is NOT gated on $flag — a disabled protocol still ships configs" ;;
        2) bad  "$label: could not find '$needle' in $(basename "$file") — test is stale" ;;
    esac
}

# --- the host path (what `moav user add` actually runs) ----------------------
check "reality.txt"    ENABLE_REALITY    'reality.txt"'    "$host"
check "trojan.txt"     ENABLE_TROJAN     'trojan.txt"'     "$host"
check "hysteria2.txt"  ENABLE_HYSTERIA2  'hysteria2.txt"'  "$host"
check "anytls.txt"     ENABLE_ANYTLS     'anytls.txt"'     "$host"
check "trusttunnel"    ENABLE_TRUSTTUNNEL 'trusttunnel_write_client_bundle' "$host"

# --- the container path must stay gated too ---------------------------------
check "reality (container)"   ENABLE_REALITY   'reality.txt"'   "$cont"
check "trojan (container)"    ENABLE_TROJAN    'trojan.txt"'    "$cont"
check "hysteria2 (container)" ENABLE_HYSTERIA2 'hysteria2.txt"' "$cont"

# --- a disabled protocol must not break the summary/QR under set -u ---------
# Once the link vars are conditional, every later use has to tolerate them being
# unset, or `moav user add` dies with "unbound variable" instead of skipping.
# Every later use of a now-conditional link var must tolerate it being unset, or
# `moav user add` dies with "unbound variable" instead of skipping the protocol.
# Checked by shape, not by an enclosing-block walk: the QR sites are `[[ -n ...
# ]] && qrencode` AND-lists rather than if-blocks, and a needle like
# 'echo "$REALITY_LINK"' also matches the redirect that writes reality.txt.
# e2e covers the runtime side by adding a user with the protocol disabled.
for site in 'qrencode -o "$OUTPUT_DIR/reality-qr.png"' 'qrencode -o "$OUTPUT_DIR/reality-ipv6-qr.png"'; do
    line=$(grep -F "$site" "$host" | head -1)
    if printf '%s' "$line" | grep -q '\-n "${REALITY_LINK'; then
        ok "$(printf '%s' "$site" | grep -oE '[a-z0-9-]+\.png') is guarded against an unset link"
    else
        bad "unguarded QR site (set -u aborts when the protocol is off): $line"
    fi
done

# --- TrustTunnel must not key on a file that outlives the toggle ------------
if grep -q 'ENABLE_TRUSTTUNNEL.*==.*"true".*&&.*-f "$TRUSTTUNNEL_CREDS"' "$host" \
   || grep -B1 '\-f "$TRUSTTUNNEL_CREDS"' "$host" | grep -q 'ENABLE_TRUSTTUNNEL'; then
    ok "TrustTunnel checks the flag, not just credentials.toml"
else
    bad "TrustTunnel gated on credentials.toml alone — that file survives disabling it"
fi

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
