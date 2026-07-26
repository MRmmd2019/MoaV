#!/bin/bash
# lib/provision.sh — the single "materialize every user" implementation.
#
# Both entry points that have to make the server match the user state use this:
#   • scripts/bootstrap.sh          (first run and every re-bootstrap)
#   • moav regenerate-users         (manual heal on a running server)
#
# They used to do it twice, differently, and the divergence caused two incidents:
# bootstrap sourced lib/sync.sh under `set -euo pipefail`, so one user's failed
# field-parse aborted the whole reconcile silently, while regenerate-users ran the
# same code in a `docker … -c` shell WITHOUT `set -e` and therefore survived. That
# is why "moav regenerate-users fixes it but bootstrap doesn't" was a real thing.
#
# SHELL-SAFETY CONTRACT (the point of this file): every step here is individually
# guarded, so it behaves identically whether the caller runs under `set -e` or
# not. One user's failure never aborts the run, and the reconcile ALWAYS gets a
# chance to run — a partial bundle is recoverable, an unreconciled server config
# means users can't connect at all.
#
# Requires (sourced by the caller first): lib/common.sh, lib/sing-box.sh,
# lib/xray.sh, lib/sync.sh. Runs inside the bootstrap container, so paths are the
# container ones (/state, /configs, /outputs, /app).

# provision_user <user_id> [force]
# Materialize one user's bundle. Returns 0 on success, 1 on failure — never
# aborts the caller.
provision_user() {
    local user_id="$1" force="${2:-}"
    [[ -n "$user_id" ]] || return 1
    if /app/generate-user.sh "$user_id" ${force:+force}; then
        return 0
    fi
    log_error "Failed to generate bundle for $user_id (continuing)"
    return 1
}

# provision_all_users [force] [sing-box-config] [xray-config] [state-users-dir]
# 1. mirror host state (/host-state, where `moav user add` writes) into the
#    volume — authoritative, and the import loops elsewhere skip existing dirs,
#    so a stale/partial dir is otherwise never repaired;
# 2. materialize a bundle for every user that has credentials;
# 3. reconcile all of them into the sing-box/xray configs.
# Echoes one "  <user> … ok/FAILED" line per user so callers can show progress.
# Always returns 0: the caller decides what a partial result means.
provision_all_users() {
    local force="${1:-}"
    local sb="${2:-/configs/sing-box/config.json}"
    local xr="${3:-/configs/xray/config.json}"
    local users_dir="${4:-${STATE_DIR:-/state}/users}"

    # 1. host state wins
    if [[ -d /host-state/users ]]; then
        mkdir -p "$users_dir" 2>/dev/null || true
        cp -a /host-state/users/. "$users_dir/" 2>/dev/null || true
    fi

    # 2. per-user bundles
    local d u ok=0 failed=0
    if [[ -d "$users_dir" ]]; then
        for d in "$users_dir"/*/; do
            [[ -d "$d" ]] || continue
            u=$(basename "$d")
            # No credentials => nothing to render from; not an error.
            [[ -f "${d}credentials.env" ]] || continue
            if provision_user "$u" "$force"; then
                echo "  $u … ok"
                ok=$((ok + 1))
            else
                echo "  $u … FAILED"
                failed=$((failed + 1))
            fi
        done
    fi

    # 3. reconcile — must run even if some bundles failed above
    if sync_server_users "$sb" "$xr" "$users_dir"; then
        log_info "Provisioned $ok user(s) into configs + bundles${failed:+, $failed failed}"
    else
        log_error "Reconcile of the server proxy configs failed"
    fi
    return 0
}
