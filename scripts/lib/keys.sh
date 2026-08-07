#!/bin/bash
# lib/keys.sh — single-source key generation for provisioning.
#
# Sourced by both the host scripts (scripts/lib/keys.sh) and the container ones
# (/app/lib/keys.sh). WireGuard and AmneziaWG use the same Curve25519 key format,
# so one generator serves both.
#
# CRLF-safe by construction: `docker compose exec` into some images emits CRLF,
# and $() strips only the trailing \n — a leftover \r makes a 44-char key 45
# chars, which `wg/awg pubkey` rejects, silently writing a broken peer. Every
# path here pipes through `tr -d '\r\n'`.

# WireGuard/AmneziaWG keys ARE X25519 keys: `wg genkey` is 32 random clamped
# bytes and `wg pubkey` is the X25519 base-point multiply. openssl does both, so
# a host with no wireguard-tools can still mint valid keys with no container in
# the loop. Verified live: openssl-derived public keys are byte-identical to
# `wg pubkey` and `awg pubkey` output for the same private key.
#
# This is why `moav user add` failed from the CLI while the dashboard and the
# bootstrapped demo user worked: the bootstrap image ships /usr/bin/wg (local
# binary path) and the admin container could docker-exec, but the HOST has no
# wg/awg binary, so the CLI depended entirely on reaching a container. Any
# transient docker hiccup (container mid-restart, exec killed under load)
# surfaced as "no wg/awg key generator available".
#
# openssl is present on the host, in the admin container, and in the bootstrap
# image, so this path is always available.
_keys_openssl_ok() { command -v openssl >/dev/null 2>&1; }

# Emit "<private>\n<public>" using openssl only. Returns 1 if openssl can't.
_keys_openssl_keypair() {
    _keys_openssl_ok || return 1
    local tmp priv pub
    tmp=$(mktemp 2>/dev/null) || return 1
    if ! openssl genpkey -algorithm X25519 -out "$tmp" 2>/dev/null; then
        rm -f "$tmp"; return 1
    fi
    # PKCS#8 DER: the raw 32-byte key is the tail. Same for the SPKI pubkey.
    priv=$(openssl pkey -in "$tmp" -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\r\n')
    pub=$(openssl pkey -in "$tmp" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\r\n')
    rm -f "$tmp"
    [[ ${#priv} -eq 44 && ${#pub} -eq 44 ]] || return 1
    printf '%s\n%s\n' "$priv" "$pub"
}

# Derive a public key from an existing base64 private key, openssl only.
# Wraps the 32 raw bytes in the fixed PKCS#8 X25519 prefix (octal escapes so
# busybox/dash printf handles it too), then asks openssl for the public half.
_keys_openssl_pubkey() {
    _keys_openssl_ok || return 1
    local priv="${1:-}" pub
    [[ ${#priv} -eq 44 ]] || return 1
    pub=$(
        { printf '\060\056\002\001\000\060\005\006\003\053\145\156\004\042\004\040'
          printf '%s' "$priv" | base64 -d 2>/dev/null; } \
        | openssl pkey -inform DER -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\r\n'
    )
    [[ ${#pub} -eq 44 ]] || return 1
    printf '%s' "$pub"
}

# Resolve a working wg/awg generator once and cache it. Preference:
#   1. a local `wg`/`awg` binary — present in the bootstrap container and on any
#      host with wireguard-tools (also sidesteps the container-exec hang class);
#   2. a running `wireguard`/`amneziawg` container via `docker compose exec`,
#      bounded with `timeout -k` so a wedged container can't hang `user add`;
#   3. a throwaway image (host with neither).
# openssl (above) is tried before 2/3 in wg_keypair/wg_pubkey — it needs no
# container at all, so it is both faster and immune to docker-daemon state.
_keys_resolved=""
_keys_bin=""
_keys_prefix=()   # command prefix as an array (empty for a local binary)
_keys_resolve() {
    [[ -n "$_keys_resolved" ]] && return 0
    # 60s, not 20: keygen is instant, but on a small box (1 vCPU / 1 GB) right
    # after `moav start` the exec's cold-start under container-boot contention
    # blew a 20s budget, so `moav user add` reported "no key generator" for
    # wg/awg even though the container was healthy. Seen live on bitchat.
    local t=()
    command -v timeout >/dev/null 2>&1 && t=(timeout -k 5 60)
    if command -v wg >/dev/null 2>&1; then
        _keys_bin=wg; _keys_prefix=(); _keys_resolved=1; return 0
    fi
    if command -v awg >/dev/null 2>&1; then
        _keys_bin=awg; _keys_prefix=(); _keys_resolved=1; return 0
    fi
    # Prefer `docker exec <container>` over `docker compose exec <service>`:
    # compose re-parses the whole compose file on every call (~2x slower idle,
    # far worse under load), and this runs three times per peer (ps + genkey +
    # pubkey). Container names are deterministic (moav-<service>).
    local pair svc bin cname img
    for pair in "wireguard wg" "amneziawg awg"; do
        svc=${pair% *}; bin=${pair#* }; cname="moav-$svc"
        if "${t[@]}" docker ps --filter "name=^/${cname}$" --filter status=running -q 2>/dev/null | grep -q .; then
            _keys_bin="$bin"; _keys_prefix=("${t[@]}" docker exec -i "$cname"); _keys_resolved=1; return 0
        fi
    done
    # No wg/awg container is RUNNING yet — the common case in the post-`moav
    # start`/upgrade boot window, and exactly why `moav user add` reported "no
    # key generator" while the web admin (hitting it seconds later, containers
    # up) succeeded. Fall back to a one-shot `docker run` on the SAME
    # locally-built image the container uses — resolved FROM the container so we
    # don't guess the compose-auto-named image, works whether it is stopped or
    # still booting, and it is always present after `moav build`. wg genkey and
    # awg genkey are format-compatible, so either image's binary serves both.
    # (The old fallback ran lscr.io/linuxserver/wireguard: normally not pulled —
    # so it failed offline — and it ships wg but not awg, so AmneziaWG always
    # died here regardless.)
    for pair in "wireguard wg" "amneziawg awg"; do
        svc=${pair% *}; bin=${pair#* }; cname="moav-$svc"
        img=$("${t[@]}" docker inspect -f '{{.Config.Image}}' "$cname" 2>/dev/null)
        if [[ -n "$img" ]]; then
            _keys_bin="$bin"; _keys_prefix=("${t[@]}" docker run --rm -i --entrypoint "" "$img"); _keys_resolved=1; return 0
        fi
    done
    # Nothing resolvable (pre-build, or wg/awg genuinely absent): leave a
    # host-`wg` resolution that will emit nothing, so wg_keypair returns empty
    # and the caller reports "no key generator" cleanly rather than hanging.
    _keys_bin=wg; _keys_prefix=(); _keys_resolved=1; return 0
}

# wg_privkey — emit one CRLF-clean private key.
# `< /dev/null`: genkey reads no input, and `docker exec -i` against the
# operator's TTY blocks until the timeout kills it (25s, empty output) — the
# original "no wg/awg key generator available" on an interactive `moav user add`.
wg_privkey() {
    _keys_resolve
    "${_keys_prefix[@]}" "$_keys_bin" genkey </dev/null 2>/dev/null | tr -d '\r\n'
}

# wg_pubkey <private-key> — derive the CRLF-clean public key from a private key.
# Local binary first, then openssl (no container), then whatever resolved.
wg_pubkey() {
    local out
    if command -v wg >/dev/null 2>&1; then
        printf '%s' "${1:-}" | wg pubkey 2>/dev/null | tr -d '\r\n'
        return 0
    fi
    if out=$(_keys_openssl_pubkey "${1:-}"); then
        printf '%s' "$out"
        return 0
    fi
    _keys_resolve
    printf '%s' "${1:-}" | "${_keys_prefix[@]}" "$_keys_bin" pubkey 2>/dev/null | tr -d '\r\n'
}

# Force the docker-run-on-local-image generator, bypassing the running-container
# `docker exec` path. Used as a retry when exec yields nothing — a container that
# IS running but whose exec was killed under docker-daemon contention (e.g. the
# sing-box restart mid `user add`) otherwise leaves no key and no fallback.
_keys_force_run() {
    local t=() pair svc bin cname img
    command -v timeout >/dev/null 2>&1 && t=(timeout -k 5 60)
    for pair in "wireguard wg" "amneziawg awg"; do
        svc=${pair% *}; bin=${pair#* }; cname="moav-$svc"
        img=$("${t[@]}" docker inspect -f '{{.Config.Image}}' "$cname" 2>/dev/null)
        if [[ -n "$img" ]]; then
            _keys_bin="$bin"; _keys_prefix=("${t[@]}" docker run --rm -i --entrypoint "" "$img"); _keys_resolved=1; return 0
        fi
    done
    return 1
}

# wg_keypair — emit "<private>\n<public>" (both CRLF-clean). Returns 1 if no
# generator produced a key. Callers: { read -r PRIV; read -r PUB; } < <(wg_keypair)
wg_keypair() {
    local priv pub kp
    # 1. Local wg/awg binary — canonical and instant (bootstrap image, or a host
    #    with wireguard-tools).
    if command -v wg >/dev/null 2>&1 || command -v awg >/dev/null 2>&1; then
        priv=$(wg_privkey)
        pub=$(wg_pubkey "$priv")
    fi
    # 2. openssl, entirely local. This is what makes the host CLI reliable: no
    #    container, no docker daemon, nothing to time out or be mid-restart.
    if [[ -z "${priv:-}" || -z "${pub:-}" ]] && kp=$(_keys_openssl_keypair); then
        priv=$(printf '%s' "$kp" | head -1)
        pub=$(printf '%s' "$kp" | tail -1)
    fi
    # 3. Last resort: the containers (running exec, else a one-shot docker run).
    if [[ -z "${priv:-}" || -z "${pub:-}" ]]; then
        _keys_resolved=""
        priv=$(wg_privkey)
        pub=$(wg_pubkey "$priv")
    fi
    if [[ -z "${priv:-}" || -z "${pub:-}" ]]; then
        _keys_resolved=""
        if _keys_force_run; then
            priv=$(wg_privkey)
            pub=$(wg_pubkey "$priv")
        fi
    fi
    [[ -n "${priv:-}" && -n "${pub:-}" ]] || return 1
    printf '%s\n%s\n' "$priv" "$pub"
}
