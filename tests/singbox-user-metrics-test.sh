#!/bin/bash
# Regression test: sing-box per-user Grafana metrics must come from the log, and
# the MahsaNet ads link must never carry a config URI.
#
# Two live bugs, both found post-v2:
#
# 1. Every per-user panel on the sing-box dashboard read zero while traffic was
#    flowing (Active Users 0, Total Users 0, empty User Connections) — 41,382
#    Reality log lines over 19h and not one attributed user. Cause: removing the
#    raw Docker socket replaced the log tailer with Clash API polling, and the
#    exporter read `metadata["inboundUser"]`. That field does not exist. Probed
#    live against 1.13.12: the /connections metadata keys are destinationIP,
#    destinationPort, dnsMode, host, network, processPath, sourceIP, sourcePort,
#    type — no user at any level, and identical in 1.13.18. The username exists
#    ONLY in the log, so sing-box now writes to a file the exporter tails (the
#    mechanism xray already used to drop the socket).
#
# 2. An audit of live donated MahsaNet records found 30 of 200 whose `ads_url`
#    was a full share link — UUIDs, trojan and hysteria2 passwords, obfs
#    passwords — published to a third party. The field is now configurable and
#    guarded, because it is one substitution away from doing that again.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exp="$ROOT/exporters/singbox/main.py"
ep="$ROOT/scripts/sing-box-entrypoint.sh"
compose="$ROOT/docker-compose.yml"
dash="$ROOT/configs/monitoring/grafana/provisioning/dashboards/singbox.json"
donate="$ROOT/lib/donate.sh"
admin="$ROOT/admin/main.py"
envex="$ROOT/.env.example"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "sing-box per-user metrics + MahsaNet ads_url tests"

# --- the exporter must not depend on the nonexistent inboundUser field --------
if grep -n 'inboundUser' "$exp" | grep -qv 'forward compat\|always absent\|#'; then
    if grep -q 'tail_singbox_log' "$exp"; then
        ok "inboundUser is still read but only as a forward-compatible extra (tailer present)"
    else
        bad "exporter relies on metadata['inboundUser'], which sing-box never emits"
    fi
else
    ok "exporter does not rely on inboundUser alone"
fi

grep -q 'def tail_singbox_log' "$exp" \
    && ok "exporter has a log tailer (the only source of usernames)" \
    || bad "exporter has no log tailer — per-user metrics cannot work"

grep -q 'tail_singbox_log, daemon=True' "$exp" \
    && ok "log tailer is started as a thread" \
    || bad "tail_singbox_log is defined but never started"

# Only new events: re-reading a retained file from the start double-counts.
grep -q 'SEEK_END' "$exp" \
    && ok "tailer seeks to EOF on attach (no replay of a retained log)" \
    || bad "tailer does not seek to EOF — a restart would re-count old events"

# The entrypoint caps the file, so the tailer must notice the shrink.
grep -qE 'st_size < fh.tell\(\)|rotated/truncated' "$exp" \
    && ok "tailer detects truncation and reattaches" \
    || bad "tailer has no truncation handling — it would sit at a stale offset"

# --- the username regex must not match the anonymous line --------------------
# sing-box logs an anonymous line first, then an attributed one. The inbound tag
# is also bracketed, so a sloppy pattern captures "vless-reality-in" as a user.
py=$(command -v python3 || true)
if [ -n "$py" ]; then
    out=$("$py" - "$exp" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"USER_PATTERN\s*=\s*re\.compile\(r'([^']+)'\)", src)
if not m:
    print("NOPATTERN"); raise SystemExit
pat = re.compile(m.group(1))
attributed = "inbound/vless[vless-reality-in]: [alice] inbound connection to www.google.com:443"
anonymous  = "inbound/vless[vless-reality-in]: inbound connection from 1.2.3.4:5678"
a = pat.search(attributed)
b = pat.search(anonymous)
print("USER=" + (a.group(1) if a else "NONE"))
print("ANON=" + (b.group(1) if b else "NONE"))
PY
)
    case "$out" in
        *"USER=alice"*) ok "pattern extracts the username from an attributed line" ;;
        *) bad "pattern failed on an attributed line ($out)" ;;
    esac
    case "$out" in
        *"ANON=NONE"*) ok "pattern does NOT match the anonymous line (no tag-as-user)" ;;
        *) bad "pattern captured the inbound tag as a username ($out)" ;;
    esac
else
    echo "  skip  regex behaviour (python3 unavailable)"
fi

# --- the log file has to actually be produced, and be readable ---------------
grep -q '"output"' "$ep" \
    && ok "entrypoint injects log.output so a file exists to tail" \
    || bad "entrypoint never sets log.output — the tailer has nothing to read"

# log.output silences the console; without a mirror `moav logs sing-box` dies.
grep -qE 'tail -n 0 -F' "$ep" \
    && ok "entrypoint mirrors the log back to stdout (moav logs still works)" \
    || bad "log.output set with no stdout mirror — moav logs sing-box would go dark"

# The exporter is root but cap_drop ALL: no DAC_OVERRIDE, so it needs world bits.
grep -q 'chmod 644' "$ep" \
    && ok "log file is chmod 644 (exporter has no DAC_OVERRIDE)" \
    || bad "log file not made world-readable — cap_drop ALL exporter cannot read it"

grep -q 'chown moav:moav "$ACCESS_LOG"' "$ep" \
    && ok "log file is owned by moav so sing-box can append to it" \
    || bad "log file not chowned to moav — sing-box runs as moav and could not write"

# sing-box cannot rotate; an uncapped log fills the volume.
grep -q 'ACCESS_LOG_MAX_BYTES' "$ep" \
    && ok "log file is size-capped" \
    || bad "no size cap on the log file"

# A bad injection must degrade to "no metrics", never to a server that won't boot.
grep -q 'sing-box check -c "$_cand"' "$ep" \
    && ok "injected config is validated before being adopted" \
    || bad "config injection is not validated — a bad edit would stop sing-box booting"

# --- the exporter must be able to see the volume -----------------------------
grep -q 'moav_logs:/var/log/sing-box:ro' "$compose" \
    && ok "singbox-exporter mounts the log volume read-only" \
    || bad "singbox-exporter cannot see /var/log/sing-box — tailer will find nothing"

grep -q 'user attribution now comes from the Clash API' "$compose" \
    && bad "compose still claims the Clash API supplies user attribution (it does not)" \
    || ok "the false 'Clash API supplies users' comment is gone"

# --- the dashboard must query what the exporter emits ------------------------
if [ -n "$py" ]; then
    out=$("$py" - "$exp" "$dash" <<'PY'
import json, re, sys
src = open(sys.argv[1]).read()
emitted = set(re.findall(r"singbox_[a-z_]+", src))
d = json.load(open(sys.argv[2]))
queried, titles = set(), set()
for p in d["panels"]:
    titles.add(p.get("title", ""))
    for t in (p.get("targets") or []):
        queried |= set(re.findall(r"\bsingbox_[a-z_]+\b", t.get("expr", "")))
missing = sorted(queried - emitted)
ids = [p.get("id") for p in d["panels"]]
print("MISSING=" + (",".join(missing) if missing else "none"))
print("DUPIDS=" + ("yes" if len(ids) != len(set(ids)) else "no"))
for want in ("Connections by User", "Traffic by Protocol"):
    print(f"HAS[{want}]=" + ("yes" if want in titles else "no"))
PY
)
    case "$out" in
        *"MISSING=none"*) ok "every metric the dashboard queries is emitted" ;;
        *) bad "dashboard queries metrics the exporter never emits ($out)" ;;
    esac
    case "$out" in
        *"DUPIDS=no"*) ok "dashboard panel ids are unique" ;;
        *) bad "dashboard has duplicate panel ids" ;;
    esac
    case "$out" in *"HAS[Connections by User]=yes"*) ok "dashboard has a Connections by User panel" ;;
        *) bad "Connections by User panel missing" ;; esac
    case "$out" in *"HAS[Traffic by Protocol]=yes"*) ok "dashboard has a Traffic by Protocol panel" ;;
        *) bad "Traffic by Protocol panel missing" ;; esac
else
    echo "  skip  dashboard cross-check (python3 unavailable)"
fi

# Protocol counting must have exactly one owner, or the panel shows two label
# sets for the same events (`vless` from the log, `vless/vless-reality-in` from
# the API) and double-counts.
if awk '/^def parse_log_line/,/^def [a-z_]+\(/' "$exp" | grep -q 'protocol_connections'; then
    bad "parse_log_line still increments protocol_connections — double-counts with the poller"
else
    ok "protocol counting has a single owner (the Clash poller)"
fi

# --- MahsaNet ads_url: configurable and guarded ------------------------------
grep -q 'MAHSANET_ADS_URL' "$envex" \
    && ok ".env.example documents MAHSANET_ADS_URL" \
    || bad "MAHSANET_ADS_URL not in .env.example"

grep -q 'motherofallvpns' "$envex" \
    && ok ".env.example defaults the ads link to the MoaV channel" \
    || bad ".env.example does not default to the MoaV channel"

if grep -q 'VahidOnline' "$donate" "$admin"; then
    bad "a hardcoded VahidOnline ads_url remains"
else
    ok "no hardcoded ads_url left in donate.sh or admin/main.py"
fi

grep -q 'MAHSANET_ADS_URL=${MAHSANET_ADS_URL' "$compose" \
    && ok "compose passes MAHSANET_ADS_URL to the admin container" \
    || bad "admin container never receives MAHSANET_ADS_URL"

# The guard is the point: this field leaked credentials once already.
for f in "$donate" "$admin"; do
    n=$(basename "$f")
    if grep -qE 'vless://|hysteria2://' "$f" && grep -qiE 'refus|default' "$f"; then
        ok "$n rejects a proxy URI as the ads link"
    else
        bad "$n has no guard against a proxy URI in ads_url"
    fi
done

if [ -n "$py" ]; then
    # Exercise the real function rather than trusting the source read.
    out=$("$py" - "$admin" <<'PY'
import importlib.util, os, sys, types
# Import just the helper without pulling in FastAPI: exec the def in isolation.
src = open(sys.argv[1]).read()
start = src.index("def _mahsanet_ads_url")
end = src.index("MAHSANET_ADS_URL = _mahsanet_ads_url()")
ns = {"os": os}
exec(src[start:end], ns)
f = ns["_mahsanet_ads_url"]
cases = {
    "": "https://t.me/motherofallvpns",
    "t.me/mychannel": "https://t.me/mychannel",
    "https://example.org/x": "https://example.org/x",
    "vless://uuid@1.2.3.4:443?x=y#name": "https://t.me/motherofallvpns",
    "hysteria2://pw@1.2.3.4:443": "https://t.me/motherofallvpns",
    "not a url": "https://t.me/motherofallvpns",
}
bad = []
for given, want in cases.items():
    os.environ["MAHSANET_ADS_URL"] = given
    got = f()
    if got != want:
        bad.append(f"{given!r} -> {got!r} (want {want!r})")
print("BAD=" + ("; ".join(bad) if bad else "none"))
PY
)
    case "$out" in
        *"BAD=none"*) ok "ads_url resolver: bare t.me upgraded, proxy URIs and junk rejected" ;;
        *) bad "ads_url resolver misbehaved: $out" ;;
    esac
fi

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
