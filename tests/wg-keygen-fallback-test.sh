#!/bin/bash
# Regression test: wg/awg key generation must survive the wg/awg container not
# being reachable via `docker exec`.
#
# `moav user add` generates client keys through scripts/lib/keys.sh. When the
# wireguard/amneziawg container is running it `docker exec`s into it; otherwise
# it falls back. The old fallback ran `docker run lscr.io/linuxserver/wireguard`,
# which (a) is normally NOT pulled on the server, so it failed offline, and
# (b) ships `wg` but NOT `awg`, so AmneziaWG keygen could never work through it.
# Live symptom: `moav user add` reported "no wg/awg key generator available" for
# wireguard AND amneziawg (the resolver's live `docker ps` check flaked under the
# daemon contention from the sing-box restart earlier in the same add), while the
# web admin — hitting the same code seconds later — succeeded.
#
# The fix: fall back to a one-shot `docker run` on the SAME locally-built image
# the container uses, resolved FROM the container (compose auto-names it) with the
# entrypoint cleared so the wg/awg binary runs. Always present after `moav build`;
# wg/awg keys are format-compatible. Functional coverage is in the e2e (real
# containers); this pins the shape that made the fix correct.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYS="$ROOT/scripts/lib/keys.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "wg/awg keygen fallback tests"

[[ -f "$KEYS" ]] || { echo "  cannot find keys.sh"; exit 1; }

# 1. The fallback resolves the image FROM the container, not a hardcoded name —
#    compose auto-names the images, so a literal name would break per-install.
grep -qE "docker inspect -f '\{\{\.Config\.Image\}\}'" "$KEYS" \
    && ok "fallback resolves the image from the container (inspect .Config.Image)" \
    || bad "fallback does not resolve the image from the container — a hardcoded image name will drift"

# 2. The fallback docker run clears the entrypoint so 'wg genkey' / 'awg genkey'
#    runs (the images' entrypoint is the service launcher, not the binary).
grep -qE 'docker run .*--entrypoint ""' "$KEYS" \
    && ok "fallback docker run clears the entrypoint so the wg/awg binary runs" \
    || bad "fallback docker run does not clear the entrypoint — it would exec the service launcher, not keygen"

# 3. lscr.io/linuxserver/wireguard must NOT be a keygen generator: it is usually
#    absent (fails offline) and has no awg. It may only appear in a comment.
if grep -nE 'lscr\.io/linuxserver/wireguard' "$KEYS" | grep -vqE '^\s*[0-9]+:\s*#'; then
    bad "keys.sh still uses lscr.io/linuxserver/wireguard as a generator (no awg, usually not pulled)"
    grep -nE 'lscr\.io/linuxserver/wireguard' "$KEYS" | sed 's/^/          /'
else
    ok "lscr.io/linuxserver/wireguard is not used as a keygen generator"
fi

# 4. The running-container fast path (docker exec) is still preferred first.
grep -qE 'docker exec -i "\$cname"' "$KEYS" \
    && ok "running container still preferred via docker exec (fast path intact)" \
    || bad "the docker exec fast path is gone — every keygen would pay docker-run startup"

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
