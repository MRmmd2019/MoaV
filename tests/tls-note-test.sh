#!/bin/bash
# Regression test: the self-signed-cert note prints when there's no DOMAIN
# (fresh install → browsers warn ERR_CERT_AUTHORITY_INVALID, expected) and stays
# silent once a DOMAIN (browser-trusted cert) is configured.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"           # print_tls_selfsigned_note
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"   # get_env_val
: "${YELLOW:=}" "${NC:=}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "tls self-signed note: shown when domainless, silent with a DOMAIN"

printf 'DOMAIN=\n' > .env
out=$(print_tls_selfsigned_note 2>&1)
if printf '%s' "$out" | grep -q "ERR_CERT_AUTHORITY_INVALID"; then
    ok "note is shown when no DOMAIN is set"
else
    bad "domainless: expected the note, got: ${out:-<empty>}"
fi

printf 'DOMAIN=vpn.example.com\n' > .env
out=$(print_tls_selfsigned_note 2>&1)
if [ -z "$out" ]; then
    ok "note is silent once a DOMAIN is set"
else
    bad "with DOMAIN: expected silence, got: $out"
fi

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"
