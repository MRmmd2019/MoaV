#!/bin/bash
# lib/xray.sh — canonical Xray (XHTTP/XDNS) server-config mutation.
#
# The single source of truth for inserting a user's VLESS client entry into the
# xray config, used by the host `user add` path and the bootstrap/regenerate
# reconcile. Adds the entry to every vless-* inbound, idempotently by id, into
# whichever field the running config uses: Xray v26.5.9 renamed
# `settings.clients` -> `settings.users` (kept `clients` as an alias), so the
# bootstrap template writes `users` while a legacy config may carry `clients`.
# Extend whichever is present rather than forcing one — matching the reconcile,
# which is authoritative for the post-bootstrap config.

# xray_add_user <config> <uuid> <username>
# Writes in place via cat-overwrite (preserving inode/mode/owner) only when the
# config changed. Returns 0 if the config changed, 1 if unchanged or on jq failure.
xray_add_user() {
    local xr="$1" id="$2" n="$3" tmp
    [[ -f "$xr" ]] || return 1
    tmp=$(mktemp)
    if jq --arg id "$id" --arg e "${n}@moav" '
            (.inbounds[] | select(.protocol=="vless" and (.tag // "" | startswith("vless-"))) | .settings) |=
              (if has("clients")
               then (if (any(.clients[]?; .id==$id) | not) then .clients += [{"id":$id,"email":$e,"flow":""}] else . end)
               else (if (any(.users[]?;   .id==$id) | not) then .users   += [{"id":$id,"email":$e,"flow":""}] else . end) end)
        ' "$xr" > "$tmp" 2>/dev/null && jq empty "$tmp" 2>/dev/null; then
        if ! cmp -s "$tmp" "$xr"; then cat "$tmp" > "$xr"; rm -f "$tmp"; return 0; fi
    fi
    rm -f "$tmp"
    return 1
}
