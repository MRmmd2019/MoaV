#!/bin/bash
# Regression test: generate-user.sh must reject a malformed credentials.env
# (empty/invalid USER_UUID or empty USER_PASSWORD) instead of emitting broken
# bundles. Unit-tests the creds_valid guard from scripts/lib/common.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"

echo "creds_valid: accepts a well-formed pair, rejects malformed credentials.env"

UUID="a3fcdcc0-5751-4b76-b45c-e38d8f0693ed"

creds_valid "$UUID" "s3cret"        && ok "accepts valid UUID + password"        || bad "valid pair rejected"
creds_valid ""      "s3cret"        && bad "empty UUID accepted"                 || ok "rejects empty UUID"
creds_valid "not-a-uuid" "s3cret"   && bad "malformed UUID accepted"             || ok "rejects malformed UUID"
creds_valid "$UUID" ""              && bad "empty password accepted"             || ok "rejects empty password"
creds_valid ""      ""              && bad "empty pair accepted"                 || ok "rejects empty pair"
# a truncated/partial UUID (e.g. from a partial write) must fail
creds_valid "a3fcdcc0-5751-4b76"    "s3cret" && bad "truncated UUID accepted"    || ok "rejects truncated UUID"

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"
