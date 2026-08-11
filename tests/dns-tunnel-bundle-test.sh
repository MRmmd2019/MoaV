#!/bin/bash
# Regression test: every enabled DNS tunnel must reach the user bundle, and a
# missing key must be loud.
#
# Bug: on a real server NO user bundle contained Slipstream or MasterDNS configs
# -- not just later users, every user including the bootstrap-created ones --
# while both services were enabled and had been running for a day. The server was
# serving two last-resort transports to nobody.
#
# Cause: `moav user add` runs on the HOST and gated each one on
# $STATE_DIR/keys/<key>, but those keys live in the moav_state volume and there is
# no keys/ directory on the host at all. Both guards were bare `if [[ -f ]]` with
# no else, so the configs were skipped silently and the command still exited 0.
#
# dnstt was unaffected because it reads outputs/dnstt/server.pub, which bootstrap
# publishes to the host bind mount. bootstrap publishes the other two the same way
# (outputs/slipstream/cert.pem, outputs/masterdns/encrypt_key.txt, both verified
# byte-identical to the volume originals) -- the host path just never looked there.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ua="$ROOT/scripts/user-add.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "DNS-tunnel bundle completeness tests"

# --- the host path must consult the published copies ------------------------
# Comments are stripped first: an earlier version of this test grepped the whole
# file and passed on the explanatory comment alone, so deleting the actual
# hydration calls still showed green.
code=$(sed 's/[[:space:]]*#.*$//' "$ua")

grep -q 'publish_to_state_keys "outputs/slipstream/cert.pem"' <<<"$code" \
    && ok "user-add hydrates from the published Slipstream cert" \
    || bad "no publish_to_state_keys call for outputs/slipstream/cert.pem — host bundles will omit Slipstream"

grep -q 'publish_to_state_keys "outputs/masterdns/encrypt_key.txt"' <<<"$code" \
    && ok "user-add hydrates from the published MasterDNS key" \
    || bad "no publish_to_state_keys call for outputs/masterdns/encrypt_key.txt — host bundles will omit MasterDNS"

grep -q 'secure_state_keys' <<<"$code" \
    && ok "hydrated keys get their modes normalized" \
    || bad "secure_state_keys not called — a root cp leaves 640 root:root, unreadable by uid 2000"

grep -q 'outputs/dnstt/server.pub' <<<"$code" \
    && ok "dnstt still reads its published pubkey (unchanged)" \
    || bad "dnstt's published pubkey read disappeared"

# --- a missing key must warn, not skip in silence ---------------------------
for proto in Slipstream MasterDNS; do
    if awk -v p="$proto" '
        $0 ~ ("ENABLE_" toupper(p)) {inblock=1}
        inblock && /log_warn/ {found=1}
        inblock && /^fi$/ {inblock=0}
        END {exit !found}' "$ua"; then
        ok "$proto logs a warning when enabled but keyless"
    else
        bad "$proto still skips silently when its key is missing"
    fi
done

# --- exercise the hydration for real ----------------------------------------
# Simulate a host layout: published files present, state/keys absent.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/outputs/slipstream" "$tmp/outputs/masterdns" "$tmp/state"
printf 'CERTDATA\n' > "$tmp/outputs/slipstream/cert.pem"
printf 'KEYDATA\n'  > "$tmp/outputs/masterdns/encrypt_key.txt"

# Extract the helper and run it in isolation, against the simulated tree.
helper=$(sed -n '/^publish_to_state_keys()/,/^}/p' "$ua")
if [ -z "$helper" ]; then
    bad "publish_to_state_keys() not found — cannot test the hydration"
else
    out=$(
        cd "$tmp" || exit 1
        STATE_DIR="state"
        eval "$helper"
        publish_to_state_keys "outputs/slipstream/cert.pem"       "slipstream-cert.pem"   && echo "slip-ok"
        publish_to_state_keys "outputs/masterdns/encrypt_key.txt" "masterdns-encrypt.key" && echo "md-ok"
    )
    [[ "$out" == *slip-ok* && "$out" == *md-ok* ]] \
        && ok "helper reports success for both protocols" \
        || bad "helper failed: $out"

    [[ -s "$tmp/state/keys/slipstream-cert.pem" ]] \
        && ok "Slipstream cert landed in state/keys/" \
        || bad "Slipstream cert was not hydrated"
    [[ -s "$tmp/state/keys/masterdns-encrypt.key" ]] \
        && ok "MasterDNS key landed in state/keys/" \
        || bad "MasterDNS key was not hydrated"

    # Content must survive intact -- these keys go straight into client configs.
    [[ "$(cat "$tmp/state/keys/slipstream-cert.pem")" == "CERTDATA" ]] \
        && ok "cert content copied verbatim" || bad "cert content altered"
    [[ "$(cat "$tmp/state/keys/masterdns-encrypt.key")" == "KEYDATA" ]] \
        && ok "key content copied verbatim" || bad "key content altered"

    # An existing container-style key must win: the volume copy is canonical, and
    # clobbering it from outputs/ would let a stale publish overwrite live material.
    printf 'CANONICAL\n' > "$tmp/state/keys/slipstream-cert.pem"
    (
        cd "$tmp" || exit 1
        STATE_DIR="state"; eval "$helper"
        publish_to_state_keys "outputs/slipstream/cert.pem" "slipstream-cert.pem"
    ) >/dev/null 2>&1
    [[ "$(cat "$tmp/state/keys/slipstream-cert.pem")" == "CANONICAL" ]] \
        && ok "an existing key is not overwritten by the published copy" \
        || bad "hydration clobbered an existing key"

    # The whole hydration block must survive `set -euo pipefail` in both states:
    # nothing to do (container layout, keys already present) and a missing source.
    # Run the real block from the script rather than a paraphrase of it.
    block=$(sed -n '/^_hydrated=0/,/^unset _hydrated/p' "$ua")
    for state in already-present missing-source; do
        [[ "$state" == "missing-source" ]] && rm -f "$tmp/state/keys/"* "$tmp/outputs/slipstream/cert.pem"
        got=$(
            cd "$tmp" || exit 1
            set -euo pipefail
            STATE_DIR="state"
            secure_state_keys() { :; }
            eval "$helper"
            eval "$block"
            echo "survived"
        ) 2>&1
        [[ "$got" == *survived* ]] \
            && ok "hydration block survives strict mode ($state)" \
            || bad "hydration block aborts under set -e ($state): $got"
    done
    # Restore for the checks below.
    printf 'CERTDATA\n' > "$tmp/outputs/slipstream/cert.pem"

    # Nothing to publish must fail cleanly rather than creating an empty key,
    # which would pass the -s guard downstream and emit a broken config.
    rm -f "$tmp/state/keys/masterdns-encrypt.key" "$tmp/outputs/masterdns/encrypt_key.txt"
    (
        cd "$tmp" || exit 1
        STATE_DIR="state"; eval "$helper"
        publish_to_state_keys "outputs/masterdns/encrypt_key.txt" "masterdns-encrypt.key"
    ) >/dev/null 2>&1
    [[ ! -e "$tmp/state/keys/masterdns-encrypt.key" ]] \
        && ok "a missing source creates no empty key file" \
        || bad "hydration created an empty/placeholder key"
fi

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
