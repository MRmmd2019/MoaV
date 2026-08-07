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

# 4. The running-container fast path (docker exec) is still available.
grep -qE 'docker exec -i "\$cname"' "$KEYS" \
    && ok "running container still available via docker exec" \
    || bad "the docker exec path is gone"

# --- 5. keygen must not depend on docker AT ALL --------------------------------
# wg/awg keys ARE X25519 keys, so openssl can mint them locally. This is what
# made `moav user add` reliable from the host CLI: the bootstrap image ships
# /usr/bin/wg and the admin container could docker-exec, but the HOST has no
# wg/awg binary, so the CLI depended entirely on reaching a container and any
# transient docker hiccup surfaced as "no wg/awg key generator available".
grep -q '_keys_openssl_keypair()' "$KEYS" \
    && ok "keys.sh has a local openssl keypair generator" \
    || bad "no local openssl generator — the host CLI is back to needing a container"
grep -q '_keys_openssl_pubkey()' "$KEYS" \
    && ok "keys.sh can derive a pubkey locally with openssl" \
    || bad "no local openssl pubkey derivation"

# functional: the openssl path yields real 44-char keys and round-trips
if command -v openssl >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    ( set +u; source "$KEYS" >/dev/null 2>&1
      kp=$(_keys_openssl_keypair) || exit 1
      p=$(printf '%s' "$kp" | head -1); q=$(printf '%s' "$kp" | tail -1)
      [ ${#p} -eq 44 ] && [ ${#q} -eq 44 ] || exit 1
      d=$(_keys_openssl_pubkey "$p") || exit 1
      [ "$d" = "$q" ] || exit 1 ) \
      && ok "openssl generator yields 44-char keys whose pubkey re-derives identically" \
      || bad "openssl keypair/pubkey round-trip failed"

    # ...and wg_keypair itself must succeed with docker made unreachable.
    ( set +u; source "$KEYS" >/dev/null 2>&1
      export DOCKER_HOST=tcp://127.0.0.1:1
      k=$(wg_keypair) || exit 1
      [ "$(printf '%s' "$k" | wc -l)" -eq 1 ] || exit 1 ) \
      && ok "wg_keypair succeeds with docker unreachable (no container in the loop)" \
      || bad "wg_keypair still needs docker — the CLI failure class is back"
else
    ok "openssl absent on this runner; skipped functional keygen checks"
fi

# --- 6. no running-container gate may hide WireGuard from a user --------------
# `docker compose ps` interpolates .env, which the non-root admin container
# cannot read, so the gate answered "not running" for a container that was up
# and the dashboard silently produced a bundle with NO wireguard.conf.
UA="$ROOT/scripts/user-add.sh"
grep -q 'Skipping WireGuard (service not running)' "$UA" \
    && bad "user-add.sh still gates WireGuard on a running check — dashboard users silently lose wireguard.conf" \
    || ok "no running-container gate around the WireGuard add"

# --- 7. container checks/execs go by container name, not docker compose -------
grep -q 'svc_running()' "$ROOT/scripts/lib/common.sh" && grep -q 'svc_exec()' "$ROOT/scripts/lib/common.sh" \
    && ok "common.sh provides container-name svc_running/svc_exec helpers" \
    || bad "svc_running/svc_exec missing — in-container callers fall back to broken compose lookups"
for s in user-add.sh wg-user-add.sh; do
    if grep -qE 'compose_timeout (ps (wireguard|amneziawg|sing-box)|exec -T (wireguard|amneziawg|sing-box))' "$ROOT/scripts/$s"; then
        bad "$s still uses 'docker compose ps/exec' for wg/awg/sing-box — fails inside the admin container"
    else
        ok "$s uses container-name helpers for wg/awg/sing-box"
    fi
done

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
