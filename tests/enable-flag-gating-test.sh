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

# --- donate mode ------------------------------------------------------------
# Donate mode hands configs to another network (MahsaNet); recipients paste a
# share link into a phone app. Anything needing a client daemon, a tunnel device
# or a DNS delegation cannot be donated. Reference: docs/devdocs/DONATE-MODE.md
#
# The overrides used to live inline in user-add.sh, un-exported, and every
# sub-script then re-sourced .env -- so they never reached singbox-user-add.sh
# or wg-user-add.sh and donated users got the operator's full protocol set.
common="$ROOT/scripts/lib/common.sh"

grep -q '^apply_donate_mode()' "$common" \
    && ok "apply_donate_mode is shared in lib/common.sh" \
    || bad "apply_donate_mode is not in lib/common.sh — each path would drift"

for s in user-add.sh singbox-user-add.sh wg-user-add.sh; do
    if grep -q '^apply_donate_mode' "$ROOT/scripts/$s"; then
        ok "$s applies donate mode"
    else
        bad "$s never applies donate mode — it re-sources .env and loses the overrides"
    fi
done

# Every override must be EXPORTED, or the sub-scripts cannot see it. Checked by
# running the function and reading the environment it leaves behind -- a textual
# check misreads a multi-line `export a=1 \\\n b=2` as unexported continuations.
donate_env=$(
    set +u
    # shellcheck disable=SC1090
    source "$common" >/dev/null 2>&1
    DONATE_ONLY_PROTOCOLS="reality hysteria2"
    apply_donate_mode
    env | grep -E '^(ENABLE_|CDN_SUBDOMAIN)' | sort
)
for want in ENABLE_WIREGUARD=false ENABLE_AMNEZIAWG=false ENABLE_TRUSTTUNNEL=false \
            ENABLE_GOOSERELAY=false ENABLE_DNSTT=false ENABLE_SLIPSTREAM=false \
            ENABLE_MASTERDNS=false ENABLE_XDNS=false \
            ENABLE_REALITY=true ENABLE_HYSTERIA2=true \
            ENABLE_TROJAN=false ENABLE_SS=false ENABLE_XHTTP=false ENABLE_TELEMT=false; do
    if printf '%s\n' "$donate_env" | grep -qx "$want"; then
        ok "donate mode exports $want"
    else
        got=$(printf '%s\n' "$donate_env" | grep "^${want%%=*}=" || echo "<unset>")
        bad "donate mode: expected $want, got $got"
    fi
done

# The non-donatable set must stay forced off.
for p in WIREGUARD AMNEZIAWG TRUSTTUNNEL GOOSERELAY DNSTT SLIPSTREAM MASTERDNS XDNS; do
    if awk '/^apply_donate_mode\(\)/,/^}/' "$common" | grep -q "ENABLE_$p=false"; then
        ok "donate mode forces ENABLE_$p off"
    else
        bad "donate mode does not disable $p — not donatable, needs a daemon/tunnel/DNS"
    fi
done

# CDN has no ENABLE_ flag; clearing CDN_SUBDOMAIN does not stick because the
# generator re-reads .env when it is empty, so it needs the predicate.
grep -q '^donate_allows()' "$common" \
    && ok "donate_allows() exists for flagless protocols" \
    || bad "no donate_allows() — CDN cannot be excluded from a donation"
grep -q 'donate_allows cdn' "$ROOT/scripts/singbox-user-add.sh" \
    && ok "CDN generation is gated by donate_allows" \
    || bad "CDN is not gated — donated users get a CDN link they did not ask for"

# The shipped donation default must be a subset of what donate mode can actually
# grant. A typo ("shadowsock") or a tunnel protocol here would silently donate
# nothing for that entry, since apply_donate_mode only matches known tokens.
donatable="reality trojan anytls hysteria2 shadowsocks telegram xhttp cdn"
defaults=$(grep -E '^MAHSANET_PROTOCOLS=' "$ROOT/.env.example" | cut -d= -f2- | tr -d '"')
for tok in $defaults; do
    case " $donatable " in
        *" $tok "*) ok "MAHSANET_PROTOCOLS default '$tok' is donatable" ;;
        *)          bad "MAHSANET_PROTOCOLS default '$tok' is not in the donatable set — it would donate nothing" ;;
    esac
done


echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
