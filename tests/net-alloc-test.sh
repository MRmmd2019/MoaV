#!/bin/bash
# =============================================================================
# Unit test for net_next_free_octet (scripts/lib/common.sh) — the shared
# collision-safe WireGuard/AmneziaWG peer-IP allocator.
#
# Guards the bug it was written to kill: the old peer-count+1 scheme reused the
# IPs of revoked users, so a gap in the peer list handed a *live* address to a
# new user (observed as 26 WG / 28 AWG duplicate octets on a real server). The
# allocator instead picks max-used+1 over the config scan ∪ live-interface octets.
#
# Pure function, no stack required — runs in ci.yml alongside the golden test.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
source scripts/lib/common.sh

pass=0 fail=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# eq <label> <expected> <actual>
eq() {
    if [[ "$2" == "$3" ]]; then
        echo "PASS $1 (=$3)"; pass=$((pass + 1))
    else
        echo "FAIL $1: expected '$2' got '$3'"; fail=$((fail + 1))
    fi
}
# returns_full <label> — expects the function to fail (network exhausted)
returns_full() {
    if net_next_free_octet "$1" "10.66.66" >/dev/null 2>&1; then
        echo "FAIL $2: expected exhaustion (rc!=0) but it returned a value"; fail=$((fail + 1))
    else
        echo "PASS $2 (exhaustion signalled)"; pass=$((pass + 1))
    fi
}

mkconf() { printf '%s\n' "$@" > "$WORK/c"; echo "$WORK/c"; }

# 1. Missing/empty config -> first host octet .2 (server is .1)
eq "empty-file"     2 "$(net_next_free_octet "$WORK/does-not-exist" 10.66.66)"
eq "no-peers"       2 "$(net_next_free_octet "$(mkconf '[Interface]' 'Address = 10.66.66.1/24')" 10.66.66)"

# 2. Contiguous peers -> max+1
c=$(mkconf 'AllowedIPs = 10.66.66.2/32' 'AllowedIPs = 10.66.66.3/32' 'AllowedIPs = 10.66.66.4/32')
eq "contiguous"     5 "$(net_next_free_octet "$c" 10.66.66)"

# 3. GAP (revoked user) -> still max+1, never refills the hole into a live IP.
#    Peers .2 .3 .5 (.4 revoked): old count+1 scheme would collide on .5; we pick .6.
c=$(mkconf 'AllowedIPs = 10.66.66.2/32' 'AllowedIPs = 10.66.66.3/32' 'AllowedIPs = 10.66.66.5/32')
eq "gap-collision-safe" 6 "$(net_next_free_octet "$c" 10.66.66)"

# 4. Dual-stack line (v4 + v6 on one AllowedIPs) -> octet read from the v4 form.
c=$(mkconf 'AllowedIPs = 10.66.66.9/32, fd00:cafe:beef::9/128')
eq "dual-stack"     10 "$(net_next_free_octet "$c" 10.66.66)"

# 5. Extra live-interface octets merge with the config scan (host drift guard).
#    Config max is .5 but the running interface still has .40 -> next is .41.
c=$(mkconf 'AllowedIPs = 10.66.66.2/32' 'AllowedIPs = 10.66.66.5/32')
eq "merge-live-octets" 41 "$(net_next_free_octet "$c" 10.66.66 7 40 12)"

# 6. AWG prefix works the same (different /24).
c=$(mkconf 'AllowedIPs = 10.67.67.2/32' 'AllowedIPs = 10.67.67.140/32')
eq "awg-prefix"     141 "$(net_next_free_octet "$c" 10.67.67)"

# 7. Malformed / non-numeric AllowedIPs octets are ignored, not fatal.
c=$(mkconf 'AllowedIPs = 10.66.66.x/32' 'AllowedIPs = 10.66.66.3/32')
eq "ignore-garbage" 4 "$(net_next_free_octet "$c" 10.66.66)"

# 8. Exhaustion: .254 in use -> no free octet (rc != 0).
c=$(mkconf 'AllowedIPs = 10.66.66.254/32')
returns_full "$c" "exhaustion"

echo "-------------------------------------------"
echo "net-alloc-test: $pass passed, $fail failed"
[[ "$fail" == "0" ]]
