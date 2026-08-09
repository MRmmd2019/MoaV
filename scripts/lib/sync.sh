#!/bin/bash
# lib/sync.sh — reconcile the server proxy configs with the user state.
#
# The sing-box and xray configs are regenerated from templates on every
# bootstrap (envsubst), which wipes the per-user entries that `moav user add`
# inserts incrementally. `sync_server_users` re-inserts EVERY user from state
# into those configs, idempotently, reusing each user's STORED credentials — so
# an update/re-bootstrap can never orphan a user, and already-distributed
# bundles keep working (no fresh UUIDs). Sourced by bootstrap.sh; also driven by
# `moav regenerate-users`.

# sync_server_users [sing-box-config] [xray-config] [state-users-dir]
# Returns the number of users newly re-inserted into the sing-box config.
sync_server_users() {
    local sb="${1:-/configs/sing-box/config.json}"
    local xr="${2:-/configs/xray/config.json}"
    local users_dir="${3:-${STATE_DIR:-/state}/users}"
    [[ -f "$sb" ]] || return 0
    [[ -d "$users_dir" ]] || return 0

    local d u uuid pass ss added=0
    for d in "$users_dir"/*/; do
        [[ -d "$d" ]] || continue
        u=$(basename "$d")
        [[ -f "${d}credentials.env" ]] || continue
        # `|| true` on every parse: this lib is sourced into bootstrap.sh, which
        # runs under `set -euo pipefail`. A user with no SS (shadowsocks.env
        # absent) makes sed exit non-zero → pipefail → the whole bootstrap aborts
        # silently mid-reconcile. Same for a grep/sed that finds no match. Guard
        # each so a missing file or empty field is a skip, never a fatal error.
        uuid=$(grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "${d}credentials.env" 2>/dev/null | head -1) || true
        pass=$(sed -n 's/^USER_PASSWORD=//p' "${d}credentials.env" 2>/dev/null | head -1) || true
        ss=""
        if [[ -f "${d}shadowsocks.env" ]]; then
            ss=$(sed -n 's/^SS_USER_PSK=//p' "${d}shadowsocks.env" 2>/dev/null | head -1) || true
        fi
        [[ -n "$uuid" ]] || continue

        # Re-insert into the sing-box + xray proxy configs via the canonical
        # mutations (lib/sing-box.sh, lib/xray.sh). Each is independently
        # idempotent and reuses the user's stored creds, so a re-bootstrap can
        # never orphan a user or hand out fresh UUIDs. `if`/`|| true` guard the
        # return under bootstrap's `set -e` (a "no change" is return 1, not fatal).
        if singbox_add_user "$sb" "$u" "$uuid" "$pass" "$ss"; then added=$((added+1)); fi
        [[ -f "$xr" ]] && { xray_add_user "$xr" "$uuid" "$u" || true; }
    done

    [[ "$added" -gt 0 ]] && log_info "Reconciled $added user(s) into the server proxy configs"
    return 0
}
