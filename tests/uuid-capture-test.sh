#!/bin/bash
# Regression test: user credential generation must be local and single-valued,
# and the add path must survive an unreadable .env.
#
# Two live failures on `moav user add`, same root: generating the UUID via
# `docker compose exec sing-box sing-box generate uuid` tied a pure-local
# operation to docker-daemon health.
#   1. Contended exec emitted a UUID and THEN got killed by the timeout wrapper;
#      the `|| uuidgen` fallback ran too and appended a SECOND UUID. Two-line
#      USER_UUID -> corrupt credentials.env (the bare second UUID is sourced as
#      a command), failed bootstrap/regenerate-users, xray crash-loop.
#   2. With the fallback removed, set -e/pipefail turned any exec failure (e.g.
#      sing-box restarting from the PREVIOUS add's hot-reload fallback) into a
#      silent instant death: "Failed to add sing-box user" with no detail.
# Fix: generate the UUID locally (/proc/sys/kernel/random/uuid, uuidgen
# fallback) — any RFC-4122 v4 UUID is valid for VLESS/VMess; the exec bought
# nothing. Validate before use.
#
# Related: .env is root 0600, so the admin container (uid 2000) cannot read the
# mounted copy — user-add.sh printed "sed: .env: Permission denied". The read is
# now gated on -r, and compose injects .env via env_file (read host-side).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
f="$ROOT/scripts/singbox-user-add.sh"
ua="$ROOT/scripts/user-add.sh"
compose="$ROOT/docker-compose.yml"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "user credential generation tests"

UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# --- UUID generation is local: no docker/compose exec involved ---------------
if grep -nE 'USER_UUID=.*(compose|docker).*exec' "$f" >/dev/null; then
    bad "USER_UUID still generated via a container exec — ties user add to docker-daemon health"
else
    ok "USER_UUID is generated locally (no container exec)"
fi

# --- the double-capture shape must never return: a generator that can emit
# --- output AND fail, chained with || to a second generator -------------------
if grep -nE 'generate uuid[^|]*\|\| *uuidgen' "$f" >/dev/null; then
    bad "'exec generate uuid || uuidgen' is back — a timed-out exec double-captures"
else
    ok "no exec-then-uuidgen double-capture chain"
fi

# --- validated before use, with a loud failure path ---------------------------
grep -qE '\[\[ ! "\$USER_UUID" =~' "$f" \
    && ok "USER_UUID is validated before use" \
    || bad "USER_UUID is not validated — a malformed value would reach configs"
grep -qE 'Could not generate a UUID' "$f" \
    && ok "generation failure is a loud error, not a silent set -e death" \
    || bad "no explicit error when no UUID generator exists"

# --- functional: run the exact generation line; must be ONE valid UUID --------
gen() { cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' || true; }
allok=true
for i in 1 2 3; do
    u=$(gen)
    if ! { [[ "$(printf '%s' "$u" | wc -l)" -eq 0 ]] && printf '%s' "$u" | grep -qE "$UUID_RE"; }; then
        bad "generation run $i produced invalid output: [$u]"
        allok=false
        break
    fi
done
$allok && ok "local generation yields exactly one valid lowercase UUID (3/3 runs)"

# --- .env read survives the 0600 perms in the admin container -----------------
# EVERY provisioning script the admin container runs must gate its .env read on
# -r, not just -f: the first fix only covered user-add.sh and the web add still
# died in singbox-user-add.sh's own `source .env` (line: ".env: Permission
# denied" -> set -e death -> "Failed to add sing-box user").
for s in user-add.sh singbox-user-add.sh wg-user-add.sh user-revoke.sh user-package.sh; do
    sf="$ROOT/scripts/$s"
    if grep -qE '\[\[ -f \.env \]\]' "$sf"; then
        bad "$s reads .env with only -f — unreadable 0600 .env kills it in the admin container"
    elif grep -qE '\-f \.env && -r \.env' "$sf"; then
        ok "$s gates its .env read on readability (-r)"
    else
        ok "$s has no unguarded .env read"
    fi
done

# The admin container must still get the full .env, so web-admin adds keep the
# ENABLE_*/PORT_* toggles. It is no longer compose's env_file: that baked every
# value into Config.Env where `docker inspect` printed ADMIN_PASSWORD,
# REALITY_PRIVATE_KEY and MAHSANET_API_KEY. The root entrypoint loads it instead.
# Assert the invariant, not the mechanism -- either route is acceptable.
if awk '/^  admin:$/{f=1; next} f && /^  [a-z0-9_-]+:$/{f=0} f && /env_file:/{found=1} END{exit !found}' "$compose"; then
    ok "compose injects .env into the admin container via env_file"
elif grep -q '/project/.env' "$ROOT/scripts/admin-entrypoint.sh"; then
    ok "admin-entrypoint loads .env as root (no secrets in Config.Env)"
else
    bad "nothing hands .env to the admin container — web-admin adds lose the ENABLE_*/PORT_* toggles"
fi

# And compose must not put secrets back into the container config.
for secret in ADMIN_PASSWORD MAHSANET_API_KEY REALITY_PRIVATE_KEY; do
    if awk -v s="$secret" '/^  admin:$/{f=1; next} f && /^  [a-z0-9_-]+:$/{f=0} f && $0 ~ ("- " s "=") {found=1} END{exit !found}' "$compose"; then
        bad "compose puts $secret in the admin environment — docker inspect exposes it"
    else
        ok "$secret is not in the admin container config"
    fi
done

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
