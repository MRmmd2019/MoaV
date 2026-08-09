#!/bin/bash
# lib/cert.sh — TLS certificate auto-renewal scheduling and the `moav cert`
# command. Let's Encrypt certs expire after 90 days and nothing renewed them
# before v1.8.5, so a systemd timer (or a cron.d drop-in where systemd is
# absent) is installed automatically at the end of `moav start` when DOMAIN is
# set, unless CERT_AUTORENEW=false.
#
# Sourced by moav.sh after lib/common.sh: `moav start` calls
# auto_setup_cert_renew, and the dispatcher routes `moav cert` here.
#
# Definitions only — nothing here runs at source time.

# Let's Encrypt certs expire after 90 days and nothing renewed them before
# v1.8.5 — scripts/cert-renew.sh only documented a cron line. Installed
# automatically at the end of `moav start` when DOMAIN is set.

CERT_RENEW_UNIT="moav-cert-renew"
CERT_RENEW_SERVICE_PATH="/etc/systemd/system/${CERT_RENEW_UNIT}.service"
CERT_RENEW_TIMER_PATH="/etc/systemd/system/${CERT_RENEW_UNIT}.timer"
CERT_RENEW_CRON_PATH="/etc/cron.d/moav-cert-renew"

cert_renew_install() {
    local quiet="${1:-}"
    local sudo_prefix; sudo_prefix=$(_root_prefix)

    if _has_systemd; then
        if [[ $EUID -ne 0 && -z "$sudo_prefix" ]]; then
            error "Need root (or sudo) to install ${CERT_RENEW_UNIT}.timer."
            return 1
        fi
        $sudo_prefix tee "$CERT_RENEW_SERVICE_PATH" >/dev/null <<UNIT
[Unit]
Description=MoaV TLS certificate renewal
Documentation=https://github.com/MotherofallVPNs/moav
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${SCRIPT_DIR}
ExecStart=/bin/bash ${SCRIPT_DIR}/scripts/cert-renew.sh
UNIT
        $sudo_prefix tee "$CERT_RENEW_TIMER_PATH" >/dev/null <<UNIT
[Unit]
Description=MoaV TLS certificate renewal (daily)

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
        $sudo_prefix systemctl daemon-reload
        if $sudo_prefix systemctl enable --now "${CERT_RENEW_UNIT}.timer" >/dev/null 2>&1; then
            [[ "$quiet" == "--quiet" ]] || success "Installed ${CERT_RENEW_UNIT}.timer (daily renewal check)"
            [[ "$quiet" == "--quiet" ]] && info "TLS certs will now auto-renew daily (${CERT_RENEW_UNIT}.timer)"
            return 0
        fi
        error "Failed to enable ${CERT_RENEW_UNIT}.timer. Check: systemctl status ${CERT_RENEW_UNIT}.timer"
        return 1
    fi

    # No systemd (container / WSL): cron.d if a cron daemon is plausible
    if [[ -d /etc/cron.d ]]; then
        $sudo_prefix tee "$CERT_RENEW_CRON_PATH" >/dev/null <<CRON
# MoaV TLS certificate renewal (installed by: moav cert install)
17 3 * * * root /bin/bash ${SCRIPT_DIR}/scripts/cert-renew.sh >>/var/log/moav-cert-renew.log 2>&1
CRON
        [[ "$quiet" == "--quiet" ]] || success "Installed ${CERT_RENEW_CRON_PATH} (daily renewal check)"
        return 0
    fi

    error "Neither systemd nor cron.d detected — cannot schedule renewals."
    echo "  Certs expire after 90 days; run 'bash scripts/cert-renew.sh' periodically"
    echo "  with whatever scheduler this host has."
    return 1
}

cert_renew_uninstall() {
    local sudo_prefix; sudo_prefix=$(_root_prefix)
    if _has_systemd; then
        $sudo_prefix systemctl disable --now "${CERT_RENEW_UNIT}.timer" >/dev/null 2>&1 || true
        $sudo_prefix rm -f "$CERT_RENEW_TIMER_PATH" "$CERT_RENEW_SERVICE_PATH"
        $sudo_prefix systemctl daemon-reload
    fi
    [[ -f "$CERT_RENEW_CRON_PATH" ]] && $sudo_prefix rm -f "$CERT_RENEW_CRON_PATH"
    success "Removed cert auto-renewal (certs expire in ≤90 days unless renewed manually)"
}

cert_renew_scheduler_status() {
    if _has_systemd && [[ -f "$CERT_RENEW_TIMER_PATH" ]]; then
        systemctl list-timers "${CERT_RENEW_UNIT}.timer" --no-pager 2>/dev/null || true
        return 0
    fi
    if [[ -f "$CERT_RENEW_CRON_PATH" ]]; then
        info "Renewal scheduled via ${CERT_RENEW_CRON_PATH}"
        return 0
    fi
    warn "Cert auto-renewal is NOT scheduled — install with: moav cert install"
    return 1
}

cmd_cert() {
    case "${1:-status}" in
        renew)
            bash "$SCRIPT_DIR/scripts/cert-renew.sh"
            ;;
        status)
            local domain
            domain=$(get_env_val "DOMAIN" "$SCRIPT_DIR/.env" "")
            if [[ -z "$domain" ]]; then
                info "Domainless mode — no Let's Encrypt certificates in use."
                return 0
            fi
            docker compose run --rm --entrypoint certbot certbot certificates 2>/dev/null || \
                warn "Could not read certificates (is Docker running?)"
            echo ""
            cert_renew_scheduler_status || true
            ;;
        install)          cert_renew_install ;;
        uninstall|remove) cert_renew_uninstall ;;
        *)
            echo "Usage: moav cert {status|renew|install|uninstall}"
            echo ""
            echo "  status     Show certificate expiry and renewal-schedule status."
            echo "  renew      Run a renewal check now (restarts TLS services if renewed)."
            echo "  install    Install the daily auto-renewal timer (systemd, or cron.d fallback)."
            echo "  uninstall  Remove the auto-renewal timer."
            return 1
            ;;
    esac
}

# Called at the end of `moav start`: schedule renewal the first time a domain
# deployment starts. No-op if already installed, opted out
# (CERT_AUTORENEW=false), or domainless.
auto_setup_cert_renew() {
    [[ "$(get_env_val "CERT_AUTORENEW" "$SCRIPT_DIR/.env" "true")" == "true" ]] || return 0
    [[ -n "$(get_env_val "DOMAIN" "$SCRIPT_DIR/.env" "")" ]] || return 0
    if _has_systemd; then
        [[ -f "$CERT_RENEW_TIMER_PATH" ]] && return 0
    else
        [[ -f "$CERT_RENEW_CRON_PATH" ]] && return 0
    fi
    echo ""
    info "Domain deployment detected — installing daily TLS cert auto-renewal..."
    cert_renew_install --quiet || \
        warn "Auto-install failed; run 'moav cert install' manually (or set CERT_AUTORENEW=false to silence)."
}
