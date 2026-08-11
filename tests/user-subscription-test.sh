#!/bin/bash
# `moav user base64` vs `moav user sub` must stay distinguishable.
#
# A release tester pasted `moav user base64` output into Streisand and reported
# it as an invalid config. It is not a bug in the encoding: that command emits a
# zipped bundle for moav-client's e2e `bundle_b64` input. It was a naming and
# documentation failure -- AGENTS.md described it as printing the user's "base64
# subscription", the help called it a "quick import", and the ecosystem meaning
# of "base64" for a VPN user is unambiguously a subscription blob.
#
# So: keep base64 emitting a zip, give the actual subscription its own command,
# and never let the docs call base64 a subscription again.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "user subscription / bundle-blob distinction"

menu="$ROOT/lib/menu.sh"
users="$ROOT/lib/users.sh"

# --- both commands must exist and route separately -------------------------
grep -q 'cmd_user_subscription()' "$menu" \
    && ok "cmd_user_subscription exists" || bad "no cmd_user_subscription"

grep -qE '^\s+sub\|subscription\)' "$users" \
    && ok "'user sub' is routed" || bad "'user sub' is not routed"

grep -qE '^\s+base64\|b64' "$users" \
    && ok "'user base64' still routed (moav-client e2e depends on the name)" \
    || bad "'user base64' route disappeared — breaks moav-client's bundle_b64 flow"

# --- the subscription command must read subscription.txt, not re-encode ----
# Two encoders would drift; the bundle file is already the canonical format.
# Match the assignment, not any mention: the not-found error message also says
# "subscription.txt", so a looser grep passes even when the path is changed.
if awk '/^cmd_user_subscription\(\)/,/^}/' "$menu" \
     | grep -qE '(sub|local sub)=.*subscription\.txt'; then
    ok "user sub reads the bundle's subscription.txt"
else
    bad "user sub does not read subscription.txt — second format to keep in sync"
fi

# base64 must still zip. If this ever starts emitting the subscription instead,
# moav-client's e2e input silently breaks. Match the zip *invocation*: the local
# variable is itself named `zip`, so a bare grep for "zip" always passes.
if awk '/^cmd_user_base64\(\)/,/^}/' "$menu" | grep -qE '(^|[^a-z_])zip +-'; then
    ok "user base64 still emits a zip"
else
    bad "user base64 no longer zips — moav-client e2e bundle_b64 would break"
fi

# --- nothing may describe base64 as a subscription -------------------------
# This is the exact wording that caused the misreport.
offenders=""
while IFS= read -r f; do
    [ -f "$f" ] || continue
    # Any line naming `user base64` and calling it a subscription, unless it is
    # explicitly negating ("not a subscription", "NOT a client subscription").
    # No [^|]* here: in a markdown table the two halves are separated by the very
    # pipe such a class excludes, which silently exempted the AGENTS.md row that
    # caused this bug in the first place.
    # The negation match tolerates markdown emphasis: "**Not** a subscription"
    # has no literal "not a" in it, so a plain filter flags the very line that
    # states the distinction correctly.
    if grep -inE 'user base64.*subscription' "$f" 2>/dev/null \
         | grep -viE 'not[*_ ]+a |rather than|instead of|reject' | grep -q .; then
        offenders="$offenders $f"
    fi
done <<EOF
$ROOT/AGENTS.md
$ROOT/README.md
$ROOT/llms.txt
$ROOT/lib/menu.sh
$ROOT/lib/users.sh
$ROOT/docs/devdocs/E2E-TESTING.md
EOF
if [ -z "$offenders" ]; then
    ok "no doc or help calls 'user base64' a subscription"
else
    bad "these still describe 'user base64' as a subscription:$offenders"
fi

# --- the help must offer the subscription route ----------------------------
grep -q 'user sub NAME' "$menu" \
    && ok "'moav help' lists user sub" || bad "'moav help' does not list user sub"

if awk '/^cmd_user_base64\(\)/,/^}/' "$menu" | grep -qi 'moav user sub'; then
    ok "base64's own output points at the subscription command"
else
    bad "base64 never mentions 'moav user sub' — the mix-up stays uncaught"
fi

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
