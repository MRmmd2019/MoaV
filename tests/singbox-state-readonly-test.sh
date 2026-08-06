#!/bin/bash
# Regression test: sing-box must not downgrade state-key ownership.
#
# sing-box runs non-root (setpriv --reuid=moav) and used to mount moav_state
# read-write only to write its clash cache db at /state/sing-box-cache.db. To
# make that one file writable, the entrypoint ran `chown -R moav:moav /state`,
# which recursively swept in /state/keys/* and reset EVERY state secret from
# root:root to the moav uid on every start -- silently undoing the ownership
# hardening (#244) and the host-side perms repair. Verified live: a plain
# `docker compose restart sing-box` reverted a root-owned key back to 999.
#
# The fix: the cache moves to the moav-owned /var/log/sing-box volume, /state is
# mounted read-only, and the entrypoint chowns only the log volume. These asserts
# lock in each half so no one can reintroduce the downgrade.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$ROOT/scripts/sing-box-entrypoint.sh"
TMPL="$ROOT/configs/sing-box/config.json.template"
COMPOSE="$ROOT/docker-compose.yml"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "sing-box state read-only tests"

# 1. The entrypoint must NEVER chown /state -- that is the exact regression.
#    Match a chown whose target list includes /state as a path token (so
#    /var/log/... on the same line does not mask it, which is exactly how the
#    buggy `chown -R moav:moav /state /var/log/sing-box` slipped past).
if grep -nE '^[[:space:]]*chown[^#]*[[:space:]]/state([[:space:]]|/|$)' "$ENTRY" | grep -q .; then
    bad "entrypoint chowns /state -- recursively downgrades /state/keys ownership"
    grep -nE '^[[:space:]]*chown[^#]*/state' "$ENTRY" | sed 's/^/          /'
else
    ok "entrypoint never chowns /state"
fi

# 2. It still makes its own writable volume moav-owned (the cache lives here now).
grep -qE '^[^#]*chown -R moav:moav /var/log/sing-box' "$ENTRY" \
    && ok "entrypoint chowns its log/cache volume (/var/log/sing-box)" \
    || bad "entrypoint no longer chowns /var/log/sing-box -- moav cannot write its cache"

# 3. The cache db must not live under /state (the reason /state was ever RW).
grep -q '/state/sing-box-cache.db' "$TMPL" \
    && bad "config template still points the cache at /state -- forces a writable secret store" \
    || ok "config template cache path is off /state"
grep -q '"/var/log/sing-box/sing-box-cache.db"' "$TMPL" \
    && ok "config template cache path is the moav-owned log volume" \
    || bad "config template cache path is not /var/log/sing-box -- unexpected location"

# 4. Existing installs render the OLD /state cache path; the entrypoint must
#    rewrite the runtime copy so the fix self-heals without a re-bootstrap.
grep -qE "sed -i .s\|/state/sing-box-cache.db\|/var/log/sing-box/sing-box-cache.db" "$ENTRY" \
    && ok "entrypoint self-heals a stale /state cache path on the runtime config" \
    || bad "entrypoint does not rewrite a stale /state cache path -- upgrades hit a read-only write"

# 5. sing-box's state mount must be read-only, so even a future stray chown
#    cannot touch the secret store.
sb_state=$(awk '/^  sing-box:/{f=1} f&&/moav_state:\/state/{print; exit} /^  [a-z0-9_-]+:$/{if(f&&!/sing-box/)f=0}' "$COMPOSE")
if printf '%s' "$sb_state" | grep -q ':ro'; then
    ok "sing-box mounts moav_state read-only (${sb_state## })"
else
    bad "sing-box moav_state mount is not :ro -- it can still write/chown the secret store (${sb_state:-not found})"
fi

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
