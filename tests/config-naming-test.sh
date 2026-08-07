#!/bin/bash
# Regression test: every config in a user bundle carries an identifiable name.
#
# Share links already ended in "#MoaV-<Protocol>-<user>", but WireGuard-family
# configs carry no name field at all -- clients take the tunnel name from the
# FILENAME -- so every server's WireGuard tunnel imported as "wireguard" and
# users with several MoaV servers could not tell them apart.
#
# Names now include the server: "MoaV-<server>-<Protocol>-<user>", where
# <server> is DOMAIN's first label (yorkschool.xyz -> yorkschool).
#
# The WireGuard filenames are a special case. Linux `wg-quick` turns the
# basename into a network interface, and the kernel caps interface names at 15
# characters (verified on a live box: 15 accepted, 16 rejected). So they use the
# short form moav-<label5>-<wg|awg|wgws>, which is <=15 for every input.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "config naming tests"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/common.sh" >/dev/null 2>&1 || { echo "cannot source common.sh"; exit 1; }

# --- the 15-char interface-name budget, for every label source ---------------
# wgws is the longest suffix, so it is the binding case.
_len_ok() { [ ${#1} -le 15 ]; }
for spec in "yorkschool.xyz|" "mycoolserver.example.com|" "a.io|" "|203.0.113.9" "|"; do
    d="${spec%%|*}"; ip="${spec##*|}"
    over=""
    for sfx in wg awg wgws wg6 awg6; do
        n=$(DOMAIN="$d" SERVER_IP="$ip" moav_wg_basename "$sfx")
        _len_ok "$n" || over="$over $n(${#n})"
    done
    label="DOMAIN='${d:-none}' SERVER_IP='${ip:-none}'"
    [ -z "$over" ] && ok "wg basenames <=15 chars for $label" \
                   || bad "interface name too long for $label:$over — wg-quick will fail"
done

# --- the name prefix must never produce a double dash or a bare "MoaV-" gap --
p=$(DOMAIN=yorkschool.xyz SERVER_IP= moav_name_prefix)
[ "$p" = "MoaV-yorkschool-" ] && ok "domain gives the server label ($p)" \
                              || bad "unexpected prefix with a domain: [$p]"
p=$(DOMAIN= SERVER_IP=203.0.113.9 moav_name_prefix)
[ "$p" = "MoaV-203.0.113.9-" ] && ok "domainless install falls back to the IP ($p)" \
                               || bad "unexpected prefix with only an IP: [$p]"
p=$(DOMAIN= SERVER_IP= moav_name_prefix)
[ "$p" = "MoaV-" ] && ok "no domain and no IP degrades to plain MoaV- (no 'MoaV--')" \
                   || bad "bad prefix with neither domain nor IP: [$p]"
n=$(DOMAIN= SERVER_IP= moav_wg_basename wg)
[ "$n" = "moav-wg" ] && ok "no label gives moav-wg, not moav--wg" || bad "bad basename with no label: [$n]"

# --- share links carry the server label --------------------------------------
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/sing-box.sh" >/dev/null 2>&1
export USER_UUID=11111111-2222-3333-4444-555555555555 USER_PASSWORD=pw
export DOMAIN=vpn.example.com REALITY_TARGET_HOST=www.cloudflare.com
export REALITY_PUBLIC_KEY=k REALITY_SHORT_ID=s SERVER_IP=203.0.113.9
link=$(singbox_reality_link alice 203.0.113.9)
case "$link" in
    *"#MoaV-vpn-Reality-alice") ok "reality link is named MoaV-<server>-Reality-<user>" ;;
    *"#MoaV--"*)                bad "double dash in the link name: ${link##*#}" ;;
    *)                          bad "unexpected reality link name: ${link##*#}" ;;
esac

# --- readers must accept BOTH the new and the legacy filenames ---------------
# Bundles generated before the rename still have to validate, and the bundle
# guide must not print "No WireGuard config available" for a config that is
# sitting right there under its new name.
for f in tests/client-test.sh scripts/client-connect.sh; do
    src="$ROOT/$f"
    [ -f "$src" ] || continue
    if grep -q 'moav-\*-wg\.conf' "$src" && grep -q 'wireguard\.conf' "$src"; then
        ok "$(basename "$f") looks up both new and legacy WireGuard names"
    else
        bad "$(basename "$f") does not handle both new and legacy WireGuard names"
    fi
    if grep -q 'moav-\*-awg\.conf' "$src" && grep -q 'amneziawg\.conf' "$src"; then
        ok "$(basename "$f") looks up both new and legacy AmneziaWG names"
    else
        bad "$(basename "$f") does not handle both new and legacy AmneziaWG names"
    fi
done
grep -q 'moav-\*-wg\.conf' "$ROOT/scripts/lib/bundle_readme.py" \
    && ok "bundle guide resolves the renamed WireGuard configs" \
    || bad "bundle guide would show 'No WireGuard config available' for renamed configs"

# --- the globs must not overlap ----------------------------------------------
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
touch "$t/moav-yorks-wg.conf" "$t/moav-yorks-wgws.conf" "$t/moav-yorks-awg.conf"
count() { local c=0; for f in $1; do [ -e "$f" ] && c=$((c+1)); done; echo $c; }
if [ "$(count "$t/moav-*-wg.conf")" -eq 1 ] \
   && [ "$(count "$t/moav-*-awg.conf")" -eq 1 ] \
   && [ "$(count "$t/moav-*-wgws.conf")" -eq 1 ]; then
    ok "wg / awg / wgws globs each match exactly one config"
else
    bad "the wg-family globs overlap — a lookup could pick the wrong config"
fi

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
