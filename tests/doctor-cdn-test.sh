#!/bin/bash
# Regression test: `moav doctor dns` must recognise both CDNs, and the monitoring
# stack must not carry a scrape job that can never come up.
#
# Two 2.2.1 fixes:
#  - doctor's CDN check only matched Cloudflare's cf-ray, so a correctly
#    configured CloudFront distribution was reported as "not fronted" (a live
#    CloudFront path returned 404, i.e. working, while doctor called it broken).
#  - the telemt scrape job targeted telemt:9090, which telemt binds to loopback
#    with no way to change it, so that target sat permanently DOWN.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR="$ROOT/lib/doctor.sh"
PROM="$ROOT/configs/monitoring/prometheus.yml"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "doctor CDN detection + monitoring scrape targets"

# --- pull the two header regexes out of doctor.sh so the test tracks the code --
CF_RE=$(grep -oE "grep -qE '\^\(cf-ray[^']+'" "$DOCTOR" | head -1 | sed "s/grep -qE '//; s/'$//")
FRONT_RE=$(grep -oE "grep -qE '\^x-amz-cf-id[^']+'" "$DOCTOR" | head -1 | sed "s/grep -qE '//; s/'$//")
[ -n "$CF_RE" ] && ok "Cloudflare header pattern found in doctor.sh" || bad "Cloudflare pattern missing"
[ -n "$FRONT_RE" ] && ok "CloudFront header pattern found in doctor.sh" || bad "CloudFront pattern missing (the fix is not in place)"

classify() {  # <one lowercased header line>
    if printf '%s' "$1" | grep -qE "$CF_RE"; then echo Cloudflare
    elif printf '%s' "$1" | grep -qE "$FRONT_RE"; then echo CloudFront
    else echo none; fi
}

[ "$(classify 'cf-ray: 8ab')" = Cloudflare ] \
    && ok "a cf-ray header is read as Cloudflare" || bad "Cloudflare not detected"
[ "$(classify 'x-amz-cf-id: e29')" = CloudFront ] \
    && ok "an x-amz-cf-id header is read as CloudFront" || bad "CloudFront (x-amz-cf-id) not detected"
[ "$(classify 'via: 1.1 d1.cloudfront.net (cloudfront)')" = CloudFront ] \
    && ok "a cloudfront via header is read as CloudFront" || bad "CloudFront (via) not detected"
[ "$(classify 'server: nginx')" = none ] \
    && ok "a bare origin (no CDN header) is still flagged" || bad "a bare origin was mistaken for a CDN"

# the failure branch must give CloudFront-specific advice, not only Cloudflare's
grep -q 'cloudfront.net' "$DOCTOR" \
    && ok "the failure remediation branches on CloudFront vs Cloudflare" \
    || bad "remediation still assumes Cloudflare for every CDN"

# --- no scrape job may target a loopback-only endpoint -----------------------
python3 - "$PROM" <<'PY' && ok "the loopback-only telemt:9090 job is gone; telemt-api remains" \
                          || bad "a scrape job still targets telemt:9090 (permanently DOWN)"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
jobs = {j["job_name"]: j for j in d["scrape_configs"]}
targets = [t for j in jobs.values() for sc in j.get("static_configs", []) for t in sc.get("targets", [])]
sys.exit(0 if ("telemt:9090" not in targets and "telemt-api" in jobs) else 1)
PY

# --- the telemt dashboard must not query the unreachable raw metrics ----------
# We removed the telemt:9090 scrape job, so any panel on telemt_* (non-api)
# renders "No data". The dashboard must use only telemt_api_* (the exporter).
DASH="$ROOT/configs/monitoring/grafana/provisioning/dashboards/telemt.json"
raw=$(python3 - "$DASH" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
bad = set()
for p in d["panels"]:
    for t in p.get("targets", []):
        for m in re.findall(r"\btelemt_[a-z_]+", t.get("expr","")):
            if not m.startswith("telemt_api"):
                bad.add(m)
print(" ".join(sorted(bad)))
PY
)
[ -z "$raw" ] \
    && ok "the telemt dashboard queries only telemt_api_* (nothing that 9090 fed)" \
    || bad "telemt dashboard still queries unreachable raw metrics: $raw"

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
