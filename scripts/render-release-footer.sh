#!/usr/bin/env bash
# Render the footer that release.yml appends to every GitHub release body.
#
#   scripts/render-release-footer.sh            # print the footer
#   scripts/render-release-footer.sh --pre      # prepend the pre-release note
#   scripts/render-release-footer.sh --check    # verify every link resolves
#
# Community URLs come from lib/common.sh (MOAV_URL_*), the same single source the
# CLI footer uses, so the release notes and `moav help` cannot disagree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"

MODE="${1:-}"

# Docs pages, grouped for a reader of a release note rather than as a sitemap.
# Order matters: Quick Start first, because that is where a new operator lands.
docs_get_started=(
    "quick-start|Quick Start|install to first user in ~10 minutes"
    "CLIENTS|Client Setup|connect from phones and desktops"
    "DNS|DNS Configuration|records, delegations, freeing port 53"
)
docs_reference=(
    "CLI|CLI Reference|every command and flag"
    "SETUP|Setup Guide|every option, in depth"
    "MONITORING|Monitoring|Grafana dashboards and metrics"
    "TROUBLESHOOTING|Troubleshooting|symptom-first fixes"
)
docs_understand=(
    "protocols|Supported Protocols|per-protocol ports, ciphers, stealth"
    "architecture|Architecture|container topology and bundle flow"
    "threat-model|Threat Model|what is and is not protected"
    "OPSEC|OPSEC Guide|operator-side hardening"
)
docs_help=(
    "support|Support MoaV|run a server, contribute, translate, donate"
    "TRANSLATING|Translating the Docs|one page is a complete contribution"
)

emit_group() {   # <heading> <array-name>
    local heading="$1" name="$2" entry slug label blurb
    printf '**%s**\n\n' "$heading"
    eval "local items=(\"\${${name}[@]}\")"
    for entry in "${items[@]}"; do
        IFS='|' read -r slug label blurb <<<"$entry"
        printf -- '- [%s](%s/%s) — %s\n' "$label" "$MOAV_URL_DOCS" "$slug" "$blurb"
    done
    printf '\n'
}

render_pre() {
    cat <<PRE

---

> **Note:** the install command below fetches the latest **stable** release, not
> this candidate. To try this build specifically, use the \`git checkout\` steps in
> the notes above.
PRE
}

render() {
    cat <<HEAD

---

## Quick Install

\`\`\`bash
curl -fsSL $MOAV_URL_SITE/install.sh | bash
\`\`\`

This will install MoaV to \`/opt/moav\` and guide you through setup.

## Documentation

**[${MOAV_URL_DOCS#https://}]($MOAV_URL_DOCS)** — full documentation

HEAD
    emit_group "Get started"   docs_get_started
    emit_group "Reference"     docs_reference
    emit_group "Understand it" docs_understand
    emit_group "Help out"      docs_help
    cat <<TAIL
**Running it with an AI agent?** [llms.txt]($MOAV_URL_SITE/llms.txt) is a compact
orientation for coding agents; [llms-full.txt]($MOAV_URL_SITE/llms-full.txt) is the
whole corpus. Both ship as release assets.

## Community

[Telegram]($MOAV_URL_TG) · [X]($MOAV_URL_X) · [Issues]($MOAV_URL_GH/issues) · [${MOAV_URL_SITE#https://}]($MOAV_URL_SITE)
TAIL
}

# --check: every link in the rendered footer must resolve. The list used to live
# in a workflow heredoc where a renamed docs page would ship a 404 in every
# release from then on with nothing noticing.
if [[ "$MODE" == "--check" ]]; then
    status=0
    # while-read, not mapfile: mapfile is bash 4+ and macOS ships bash 3.2.
    urls=()
    while IFS= read -r u; do
        [[ -n "$u" ]] && urls+=("$u")
    done < <(render | grep -oE 'https://[^)[:space:]]+' | sed 's/[.,]$//' | sort -u)
    echo "render-release-footer: checking ${#urls[@]} links"
    for u in "${urls[@]}"; do
        code=$(curl -sS -o /dev/null -w '%{http_code}' -L --max-time 20 "$u" 2>/dev/null || echo 000)
        # One retry: a single flaky fetch should not fail a release.
        if [[ "$code" != "200" ]]; then
            sleep 2
            code=$(curl -sS -o /dev/null -w '%{http_code}' -L --max-time 20 "$u" 2>/dev/null || echo 000)
        fi
        if [[ "$code" == "200" ]]; then
            printf '  ok    %s\n' "$u"
        else
            printf '  FAIL  %s (HTTP %s)\n' "$u" "$code"
            status=1
        fi
    done
    [[ "$status" == "0" ]] || echo "render-release-footer: fix the URLs above or update this script" >&2
    exit "$status"
fi

[[ "$MODE" == "--pre" ]] && render_pre
render
