#!/bin/bash
# Regression tests for `moav user add` failing on WireGuard/AmneziaWG with
# "no wg/awg key generator available".
#
# THE ROOT CAUSE was stdin being a TTY. `docker exec -i` and `docker compose
# exec` attach stdin; when stdin is the operator's terminal the exec blocks
# reading it until the timeout kills it. Measured on a live box, same command,
# same container:
#
#   docker exec -i … wg show wg0 public-key   (TTY stdin)  -> rc=137, 25s, EMPTY
#   docker exec -i … wg show wg0 public-key   (</dev/null) -> rc=0,  220ms, key
#   docker compose exec -T … (the older form) (TTY stdin)  -> 25s, EMPTY
#
# So from an interactive shell EVERY container call in the add path silently
# timed out — keygen, the server public-key read, the hot reloads — while the
# dashboard, CI and any script (no TTY) always worked. That asymmetry is what
# made this look like load, timing or permissions for so long.
#
# Two independent hardenings are pinned here:
#   1. stdin is never a TTY for a container exec (compose_timeout, svc_exec,
#      wg_privkey redirect from /dev/null when `[ -t 0 ]`);
#   2. keygen does not need a container at all — wg/awg keys ARE X25519 keys,
#      so openssl mints them locally. Verified live: openssl-derived public keys
#      are byte-identical to `wg pubkey`/`awg pubkey` for the same private key.
#
# Also covered: the old `docker run lscr.io/linuxserver/wireguard` fallback
# (normally not pulled, and ships `wg` but not `awg`), and the dashboard gate
# that silently skipped WireGuard. Functional coverage against real containers
# lives in the e2e.
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

# --- 8. THE ROOT CAUSE: stdin must never be a TTY for a container exec --------
COMMON="$ROOT/scripts/lib/common.sh"
for fn in compose_timeout svc_exec; do
    if awk "/^${fn}\(\)/,/^}/" "$COMMON" | grep -q '\[ -t 0 \]' \
    && awk "/^${fn}\(\)/,/^}/" "$COMMON" | grep -q '< */dev/null'; then
        ok "$fn closes stdin when it is a TTY"
    else
        bad "$fn can hand the operator's TTY to a container exec — it will hang until the timeout, empty"
    fi
done
grep -q 'genkey </dev/null' "$KEYS" \
    && ok "wg_privkey runs genkey with stdin closed" \
    || bad "wg_privkey leaves stdin attached — genkey hangs on a TTY"

# The assignment that turned a failed container call into a silent mid-add death.
grep -qE 'SERVER_PUBLIC_KEY=\$\(svc_exec[^)]*\|\| true\)' "$ROOT/scripts/wg-user-add.sh" \
    && ok "SERVER_PUBLIC_KEY assignment cannot kill the script under set -e" \
    || bad "unguarded SERVER_PUBLIC_KEY=\$(...) — a failed exec kills the add with no message"

# Functional: run a snippet under a REAL pty that never sends EOF (exactly the
# operator's terminal), and see whether it returns. `cat` stands in for the
# container exec: both read stdin until EOF. The guarded form must return; the
# unguarded form must block. Asserting BOTH directions is the point — a probe
# that only checks the guarded case passes even when it proves nothing (an
# earlier `script -qec … </dev/null` version did exactly that: the closed stdin
# gave an instant EOF, so the unguarded form "passed" too).
_pty_returns() {  # $1 = shell snippet; 0 = returned in time, 1 = blocked
    python3 - "$1" <<'PY' >/dev/null 2>&1
import os, pty, select, sys
snippet = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:                       # child: stdin IS a tty, and nothing ever writes to it
    os.execvp("bash", ["bash", "-c", snippet])
buf = b""
deadline = 3.0
while deadline > 0:
    r, _, _ = select.select([fd], [], [], 0.25)
    deadline -= 0.25
    if r:
        try:
            chunk = os.read(fd, 1024)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        if b"RETURNED" in buf:
            break
os.kill(pid, 9); os.waitpid(pid, 0)
sys.exit(0 if b"RETURNED" in buf else 1)
PY
}
if command -v python3 >/dev/null 2>&1; then
    guarded='f(){ if [ -t 0 ]; then cat < /dev/null; else cat; fi; }; f; echo RETURNED'
    unguarded='f(){ cat; }; f; echo RETURNED'
    if _pty_returns "$guarded"; then
        if _pty_returns "$unguarded"; then
            bad "pty probe is not discriminating (the unguarded form returned too) — it proves nothing"
        else
            ok "under a real pty: guarded returns, unguarded blocks (probe is discriminating)"
        fi
    else
        bad "the guarded stdin pattern still blocks under a real pty"
    fi
else
    ok "no python3 for the pty probe; static guards above still enforced"
fi

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
