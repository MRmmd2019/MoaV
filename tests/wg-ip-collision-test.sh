#!/bin/bash
# Regression test: a stored WireGuard/AmneziaWG client IP must never be written
# when another peer already claims it.
#
# wireguard_add_peer loads WG_CLIENT_IP from the user's state file and used to
# trust it blindly. Duplicates arise from the old peer-count+1 allocator (which
# reused freed octets), a state restore, or regenerate-users rebuilding wg0.conf
# in an order where a fresh allocation lands on an IP a later stateful user has
# stored. The result is two [Peer] blocks with the same AllowedIPs, and
# WireGuard routes neither user.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "wg/awg stored-IP collision"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Minimal harness: real net_* helpers + add_peer, stubbed logging and keygen.
run_add() {  # <lib> <add-fn> <conf-path-var> <conf> <user> <stored-ip>
    local lib="$1" fn="$2" confvar="$3" conf="$4" user="$5" ip="$6"
    ( set -uo pipefail
      # Source FIRST — the libs hard-assign WG_CONFIG_DIR / log_* at source time,
      # so every override has to come after.
      source "$ROOT/scripts/lib/common.sh"
      source "$ROOT/scripts/lib/$lib"
      log_info() { :; }; log_warn() { :; }; log_error() { :; }
      wg_keypair() { printf 'PRIVKEY_%s\nPUBKEY_%s\n' "$user" "$user"; }
      export STATE_DIR="$WORK/state"
      eval "$confvar=\"$(dirname "$conf")\""
      mkdir -p "$STATE_DIR/users/$user"
      local envfile="$STATE_DIR/users/$user/${lib%.sh}.env"
      if [ "$fn" = wireguard_add_peer ]; then
        printf 'WG_PRIVATE_KEY=P\nWG_PUBLIC_KEY=U\nWG_CLIENT_IP=%s\n' "$ip" > "$envfile"
      else
        printf 'AWG_PRIVATE_KEY=P\nAWG_PUBLIC_KEY=U\nAWG_CLIENT_IP=%s\n' "$ip" > "$envfile"
      fi
      "$fn" "$user" >/dev/null 2>&1
      grep -E '_CLIENT_IP=' "$envfile" | head -1 | cut -d= -f2
    )
}

# --- WireGuard: a stored IP that collides gets reassigned -----------------------
CONF="$WORK/wg/wg0.conf"; mkdir -p "$WORK/wg"
cat > "$CONF" <<EOF
[Interface]
Address = 10.66.66.1/24

[Peer]
# alice
PublicKey = PUBKEY_alice
AllowedIPs = 10.66.66.5/32
EOF
# bob's state claims .5, already alice's.
newip=$(run_add "wireguard.sh" wireguard_add_peer WG_CONFIG_DIR "$CONF" bob "10.66.66.5")
[ "$newip" != "10.66.66.5" ] && [ -n "$newip" ] \
    && ok "bob's colliding stored IP was reassigned (got $newip, not .5)" \
    || bad "bob kept the colliding IP: '$newip'"
# alice must be untouched, and .5 must appear exactly once.
grep -q "AllowedIPs = 10.66.66.5/32" "$CONF" && ok "alice keeps .5" || bad "alice's IP was disturbed"
n=$(grep -c "AllowedIPs = 10.66.66.5/32" "$CONF")
[ "$n" -eq 1 ] && ok "no duplicate AllowedIPs for .5 in the config" || bad "duplicate .5 written ($n times)"

# --- a stored IP that does NOT collide is preserved -----------------------------
CONF2="$WORK/wg2/wg0.conf"; mkdir -p "$WORK/wg2"
cat > "$CONF2" <<EOF
[Interface]
Address = 10.66.66.1/24

[Peer]
# alice
PublicKey = PUBKEY_alice
AllowedIPs = 10.66.66.5/32
EOF
keep=$(run_add "wireguard.sh" wireguard_add_peer WG_CONFIG_DIR "$CONF2" carol "10.66.66.9")
[ "$keep" = "10.66.66.9" ] \
    && ok "a non-colliding stored IP is preserved (carol keeps .9)" \
    || bad "carol's free IP was needlessly changed: '$keep'"

# --- AmneziaWG has the same guard ----------------------------------------------
ACONF="$WORK/awg/awg0.conf"; mkdir -p "$WORK/awg"
cat > "$ACONF" <<EOF
[Interface]
Address = 10.67.67.1/24

[Peer]
# alice
PublicKey = PUBKEY_alice
AllowedIPs = 10.67.67.4/32
EOF
anewip=$(run_add "amneziawg.sh" amneziawg_add_peer AWG_CONFIG_DIR "$ACONF" bob "10.67.67.4")
[ "$anewip" != "10.67.67.4" ] && [ -n "$anewip" ] \
    && ok "AmneziaWG reassigns a colliding stored IP (got $anewip)" \
    || bad "AmneziaWG kept the colliding IP: '$anewip'"

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
