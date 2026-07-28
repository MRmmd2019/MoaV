#!/bin/bash
# =============================================================================
# MoaV Management Script
# Interactive CLI for managing the MoaV circumvention stack
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

# Get script directory (resolve symlinks)
# Save original working directory before changing to script dir
ORIGINAL_PWD="$PWD"

SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    # If relative symlink, resolve relative to symlink directory
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
cd "$SCRIPT_DIR"

# Version
VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "dev")

# Component versions (read from .env or use defaults)
get_component_version() {
    local var_name="$1"
    local default="$2"
    local env_file="$SCRIPT_DIR/.env"
    if [[ -f "$env_file" ]]; then
        local val
        val=$(grep "^${var_name}=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        [[ -n "$val" ]] && echo "$val" && return
    fi
    echo "$default"
}

# State file for persistent checks
PREREQS_FILE="$SCRIPT_DIR/.moav_prereqs_ok"
UPDATE_CACHE_FILE="/tmp/.moav_update_check"
LATEST_VERSION=""

# Handle Ctrl+C gracefully
goodbye() {
    echo ""
    echo -e "${CYAN}Goodbye! Stay safe out there.${NC}"
    echo ""
    exit 0
}
trap goodbye SIGINT

# -----------------------------------------------------------------------------
# Library modules. Sourced (not sub-shelled) so the dispatch `case` and every
# command function keep working unchanged. `common` must come first — it holds
# the foundation helpers the rest depend on. The globals above (colors,
# SCRIPT_DIR, VERSION, state files) are deliberately set BEFORE this point.
# -----------------------------------------------------------------------------
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/nettune.sh"   # before doctor: doctor_check_net calls nt_*
source "$SCRIPT_DIR/lib/peers.sh"     # doctor_check_peers + the --fix repair
source "$SCRIPT_DIR/lib/donate.sh"
source "$SCRIPT_DIR/lib/cert.sh"
source "$SCRIPT_DIR/lib/migrate.sh"
source "$SCRIPT_DIR/lib/dns.sh"
source "$SCRIPT_DIR/lib/update.sh"
source "$SCRIPT_DIR/lib/install.sh"
source "$SCRIPT_DIR/lib/bootstrap.sh"

# =============================================================================
# Prerequisite Checks
# =============================================================================

detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian"
    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/fedora-release ]]; then
        echo "rhel"
    elif [[ -f /etc/alpine-release ]]; then
        echo "alpine"
    else
        echo "unknown"
    fi
}

install_docker() {
    local os_type=$(detect_os)

    case "$os_type" in
        debian|rhel)
            info "Installing Docker using official install script..."
            echo ""
            curl -fsSL https://get.docker.com | sh

            # Add current user to docker group
            sudo usermod -aG docker "$(whoami)" 2>/dev/null || true

            # Start and enable Docker
            sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || true
            sudo systemctl enable docker 2>/dev/null || true

            success "Docker installed"
            echo ""
            warn "You may need to log out and back in for docker group permissions."
            warn "Or run: newgrp docker"
            return 0
            ;;
        macos)
            error "Please install Docker Desktop from: https://www.docker.com/products/docker-desktop"
            echo "After installing, run this script again."
            return 1
            ;;
        alpine)
            info "Installing Docker via apk..."
            sudo apk add docker docker-compose
            sudo rc-update add docker boot
            sudo service docker start
            success "Docker installed"
            return 0
            ;;
        *)
            error "Cannot auto-install Docker on this OS."
            echo "Please install from: https://docs.docker.com/engine/install/"
            return 1
            ;;
    esac
}

install_qrencode() {
    local os_type=$(detect_os)
    local pkg_manager=""

    # Detect package manager
    case "$os_type" in
        macos)
            if command -v brew &>/dev/null; then
                pkg_manager="brew"
            fi
            ;;
        debian)
            pkg_manager="apt"
            ;;
        rhel)
            if command -v dnf &>/dev/null; then
                pkg_manager="dnf"
            elif command -v yum &>/dev/null; then
                pkg_manager="yum"
            fi
            ;;
        alpine)
            pkg_manager="apk"
            ;;
    esac

    case "$pkg_manager" in
        brew)
            info "Installing qrencode via Homebrew..."
            brew install qrencode
            ;;
        apt)
            info "Installing qrencode via apt..."
            sudo apt update && sudo apt install -y qrencode
            ;;
        dnf)
            info "Installing qrencode via dnf..."
            sudo dnf install -y qrencode
            ;;
        yum)
            info "Installing qrencode via yum..."
            sudo yum install -y qrencode
            ;;
        apk)
            info "Installing qrencode via apk..."
            sudo apk add libqrencode-tools
            ;;
        *)
            error "Could not detect package manager"
            echo "  Please install qrencode manually:"
            echo "    Linux (Debian/Ubuntu): sudo apt install qrencode"
            echo "    Linux (RHEL/Fedora):   sudo dnf install qrencode"
            echo "    macOS:                 brew install qrencode"
            return 1
            ;;
    esac

    if command -v qrencode &>/dev/null; then
        success "qrencode installed successfully"
    else
        error "qrencode installation failed"
        return 1
    fi
}

# Read a value from .env file — handles duplicates (last wins), inline comments, and quotes
# Usage: val=$(get_env_val "ENABLE_XHTTP" "$env_file" "true")
get_env_val() {
    local key="$1" file="$2" default="${3:-}"
    local val
    val=$(grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d'=' -f2- | sed 's/#.*//' | tr -d '"' | tr -d "'" | xargs) || true
    echo "${val:-$default}"
}

# Reality fallback target — vetted lists + DNS validation (#115).
# NXDOMAIN target → every TLS hello RSTs, bundle silently breaks.
REALITY_TARGETS_GLOBAL=(
    "www.cloudflare.com:443"
    "www.apple.com:443"
    "cdn.kernel.org:443"
    "www.microsoft.com:443"
)
# SNI cover for clients inside Iran.
REALITY_TARGETS_IRAN=(
    "www.aparat.com:443"
    "digikala.com:443"
    "taghche.com:443"
)

# 0 if host has A/AAAA. Tries getent → host → nslookup. Empty host → fail.
reality_target_resolves() {
    local host="$1"
    [[ -n "$host" ]] || return 1
    if command -v getent >/dev/null 2>&1; then
        getent hosts "$host" >/dev/null 2>&1 && return 0
    fi
    if command -v host >/dev/null 2>&1; then
        host -W 4 "$host" >/dev/null 2>&1 && return 0
    fi
    if command -v nslookup >/dev/null 2>&1; then
        nslookup -timeout=4 "$host" >/dev/null 2>&1 && return 0
    fi
    return 1
}

show_vetted_reality_targets() {
    echo "  Vetted Reality fallback targets:"
    echo ""
    echo "    Global (real TLS 1.3, stable, won't go dark):"
    for t in "${REALITY_TARGETS_GLOBAL[@]}"; do
        echo "      • $t"
    done
    echo ""
    echo "    Iran-friendly (better SNI cover for clients inside Iran):"
    for t in "${REALITY_TARGETS_IRAN[@]}"; do
        echo "      • $t"
    done
}

# Validate REALITY_TARGET / XHTTP_REALITY_TARGET resolve. NXDOMAIN → re-prompt
# (≤3) and rewrite .env. Returns 1 if still invalid after retries.
validate_reality_targets() {
    local env_file="${1:-.env}"
    [[ -f "$env_file" ]] || return 0  # nothing to validate yet

    local enable_reality enable_xhttp
    enable_reality=$(get_env_val "ENABLE_REALITY" "$env_file" "true")
    enable_xhttp=$(get_env_val "ENABLE_XHTTP" "$env_file" "true")

    local key host_port host default new_target new_host attempt failed=0
    for key in REALITY_TARGET XHTTP_REALITY_TARGET; do
        case "$key" in
            REALITY_TARGET)        [[ "$enable_reality" == "true" ]] || continue ;;
            XHTTP_REALITY_TARGET)  [[ "$enable_xhttp"    == "true" ]] || continue ;;
        esac

        host_port=$(get_env_val "$key" "$env_file" "www.cloudflare.com:443")
        host="${host_port%%:*}"

        if reality_target_resolves "$host"; then
            info "$key host '$host' resolves ✓"
            continue
        fi

        warn "$key host '$host' does NOT resolve (NXDOMAIN)"
        echo "    Reality's fallback dial will fail for every TLS hello it can't auth,"
        echo "    so the inbound RSTs every probe and every legitimate client (issue #115)."
        echo ""
        show_vetted_reality_targets
        echo ""

        default="www.cloudflare.com:443"
        for attempt in 1 2 3; do
            prompt "Enter a new $key (host:port) or press Enter for $default:"
            if ! read -r new_target < /dev/tty 2>/dev/null; then
                # Non-interactive run — accept the default and move on.
                new_target=""
            fi
            new_target="${new_target:-$default}"
            new_host="${new_target%%:*}"
            if reality_target_resolves "$new_host"; then
                if grep -qE "^${key}=" "$env_file" 2>/dev/null; then
                    sed -i.bak "s|^${key}=.*|${key}=${new_target}|" "$env_file" && rm -f "${env_file}.bak"
                else
                    echo "${key}=${new_target}" >> "$env_file"
                fi
                success "$key set to $new_target"
                break
            fi
            warn "'$new_host' also does not resolve."
            if [[ "$attempt" == "3" ]]; then
                error "$key still invalid after 3 attempts — bootstrap will fail until fixed."
                failed=$((failed + 1))
            fi
        done
    done

    [[ "$failed" -eq 0 ]]
}

# Monitoring opt-in default: N below 2 GB (hang risk), Y otherwise.
monitoring_default_for_ram() {
    local total_mb
    total_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    if [[ "$total_mb" -gt 0 && "$total_mb" -lt 2048 ]]; then
        echo "n"
    else
        echo "y"
    fi
}

ensure_admin_password() {
    # Check if admin password is unset, empty, or still the insecure default
    local current_password=""
    if [[ -f ".env" ]]; then
        current_password=$(grep -E "^ADMIN_PASSWORD=" .env 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
    fi

    if [[ -z "$current_password" || "$current_password" == "change_me_to_something_secure" || "$current_password" == "admin" ]]; then
        echo ""
        echo -e "${WHITE}Admin dashboard password${NC}"
        echo "  Press Enter to generate a random password, or type your own"
        printf "  Password: "
        input_password=""
        read -r input_password || true   # EOF on closed stdin → fall through to auto-gen
        if [[ -z "$input_password" ]]; then
            input_password=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
        fi

        if grep -q "^ADMIN_PASSWORD=" .env 2>/dev/null; then
            sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=\"$input_password\"|" .env
        else
            echo "ADMIN_PASSWORD=\"$input_password\"" >> .env
        fi
        success "Admin password configured"
        echo ""

        # Show password prominently
        echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
        echo -e "  ${WHITE}Admin Password:${NC} ${CYAN}$input_password${NC}"
        echo ""
        echo -e "  ${YELLOW}⚠ IMPORTANT: Save this password! It's also stored in .env${NC}"
        echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
        echo ""
        return 0
    fi
    return 0  # already set — no-op, not an error (returning 1 here aborts under `set -e`)
}

check_prerequisites() {
    local missing=0

    print_section "Checking Prerequisites"

    # Check Docker
    if command -v docker &> /dev/null; then
        success "Docker is installed"
    else
        warn "Docker is not installed"
        if confirm "Install Docker now?"; then
            if install_docker; then
                success "Docker installed"
            else
                missing=1
            fi
        else
            error "Docker is required"
            echo "  Install from: https://docs.docker.com/get-docker/"
            missing=1
        fi
    fi

    # Check Docker Compose (only if Docker is installed)
    if command -v docker &> /dev/null; then
        if docker compose version &> /dev/null; then
            success "Docker Compose is installed"
        else
            warn "Docker Compose is not installed"
            echo "  Docker Compose plugin is usually included with Docker."
            echo "  If you installed Docker manually, install Compose from:"
            echo "  https://docs.docker.com/compose/install/"
            missing=1
        fi
    fi

    # Check .env file
    if [[ -f ".env" ]]; then
        success ".env file exists"
        # Validate critical fields — covers the case where a previous
        # interactive bootstrap was aborted mid-prompt (e.g. user typed
        # DOMAIN, Ctrl-C'd before ACME_EMAIL / ADMIN_PASSWORD). Without
        # this we'd silently skip every missing field on the next run.
        local _existing_domain
        _existing_domain=$(get_env_val "DOMAIN" ".env" "")
        if [[ -n "$_existing_domain" ]]; then
            # Auto-clean a malformed DOMAIN (e.g. "https://t7d.my/" → "t7d.my").
            if [[ "$_existing_domain" =~ ^https?:// ]] || [[ "$_existing_domain" == */* ]] || [[ "$_existing_domain" == *:* ]]; then
                local _cleaned
                _cleaned=$(sanitize_domain "$_existing_domain")
                if is_valid_domain "$_cleaned"; then
                    warn "DOMAIN in .env was malformed: '$_existing_domain' → cleaning to '$_cleaned'"
                    update_env_var ".env" "DOMAIN" "\"$_cleaned\""
                    _existing_domain="$_cleaned"
                else
                    warn "DOMAIN in .env looks invalid: '$_existing_domain' — edit .env or re-run with an empty .env to re-prompt."
                fi
            fi
            # DOMAIN set → ACME_EMAIL is needed for Let's Encrypt.
            local _existing_email
            _existing_email=$(get_env_val "ACME_EMAIL" ".env" "")
            if [[ -z "$_existing_email" ]]; then
                echo ""
                warn "ACME_EMAIL is not set (required for Let's Encrypt TLS certificate)."
                echo -e "${WHITE}Email address${NC} (for Let's Encrypt TLS certificate)"
                printf "  Email: "
                local input_email_resume=""
                read -r -e input_email_resume
                if [[ -n "$input_email_resume" ]]; then
                    update_env_var ".env" "ACME_EMAIL" "\"$input_email_resume\""
                    success "Email set to: $input_email_resume"
                else
                    warn "No email set — edit .env later or run bootstrap again."
                fi
            fi
        fi
        # Always check admin password (idempotent — no-op if already set securely).
        ensure_admin_password
    else
        warn ".env file not found"
        if [[ -f ".env.example" ]]; then
            if confirm "Copy .env.example to .env?" "y"; then
                cp .env.example .env
                success "Created .env from .env.example"
                echo ""
                echo -e "${CYAN}Configure your MoaV installation:${NC}"
                echo ""

                # Ask for domain — loop until valid hostname, empty (domainless),
                # or 3 invalid tries.
                echo -e "${WHITE}Domain name${NC} (required for TLS-based protocols)"
                echo "  Example: vpn.example.com"
                echo "  Leave empty to run only domainless services"

                local input_domain="" _attempts=0
                while true; do
                    printf "  Domain: "
                    read -r -e input_domain
                    [[ -z "$input_domain" ]] && break    # empty = domainless

                    local raw_domain="$input_domain"
                    input_domain=$(sanitize_domain "$input_domain")
                    if [[ "$input_domain" != "$raw_domain" ]]; then
                        info "Cleaned input: '$raw_domain' → '$input_domain'"
                    fi
                    if is_valid_domain "$input_domain"; then
                        break
                    fi
                    _attempts=$((_attempts + 1))
                    warn "'$raw_domain' isn't a valid hostname (need at least one dot, only letters/digits/dots/hyphens, no spaces or special chars)."
                    if [[ $_attempts -ge 3 ]]; then
                        echo ""
                        warn "Three invalid tries — saving the last value as-is. Edit .env manually if needed."
                        break
                    fi
                    echo "  Please try again, or leave empty for domainless mode."
                done

                local domainless_mode=false
                if [[ -n "$input_domain" ]]; then
                    update_env_var ".env" "DOMAIN" "\"$input_domain\""
                    success "Domain set to: $input_domain"
                    echo ""

                    # Ask for email (only if domain is set)
                    echo -e "${WHITE}Email address${NC} (for Let's Encrypt TLS certificate)"
                    printf "  Email: "
                    read -r -e input_email
                    if [[ -n "$input_email" ]]; then
                        update_env_var ".env" "ACME_EMAIL" "\"$input_email\""
                        success "Email set to: $input_email"
                    else
                        warn "No email set - you can edit .env later"
                    fi

                    # Detect server IP and show DNS template
                    echo ""
                    info "Detecting server IP..."
                    local detected_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "YOUR_SERVER_IP")
                    if [[ "$detected_ip" != "YOUR_SERVER_IP" ]]; then
                        success "Detected IP: $detected_ip"
                        # Save to .env
                        if grep -q "^SERVER_IP=" .env 2>/dev/null; then
                            sed -i "s|^SERVER_IP=.*|SERVER_IP=\"$detected_ip\"|" .env
                        else
                            echo "SERVER_IP=\"$detected_ip\"" >> .env
                        fi
                    fi
                    echo ""

                    # Show DNS configuration template
                    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
                    echo -e "${WHITE}  DNS Configuration Required${NC}"
                    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
                    echo ""
                    echo "  Add these DNS records in your DNS provider (e.g., Cloudflare):"
                    echo ""
                    echo -e "  ${WHITE}Required Records:${NC}"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "Type" "Name" "Value" "Proxy" "Used by"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "────" "────" "─────" "────" "───────"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "A" "@" "$detected_ip" "DNS only (gray)" "Reality, Trojan, Hysteria2, XHTTP, WG"
                    echo ""
                    echo -e "  ${WHITE}For DNS Tunnels (dnstt, Slipstream, MasterDNS, XDNS):${NC}"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "A" "dns" "$detected_ip" "DNS only (gray)" "NS delegation target"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "NS" "t" "dns.$input_domain" "-" "dnstt"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "NS" "s" "dns.$input_domain" "-" "Slipstream"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "NS" "m" "dns.$input_domain" "-" "MasterDNS"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "NS" "x" "dns.$input_domain" "-" "XDNS"
                    echo ""
                    echo -e "  ${WHITE}Optional - CDN Mode (Cloudflare proxied):${NC}"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "A" "cdn" "$detected_ip" "Proxied (orange)" "CDN VLESS"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "A" "grafana" "$detected_ip" "Proxied (orange)" "Grafana dashboard"
                    echo ""
                    echo -e "  ${YELLOW}⚠ CDN Mode requires an Origin Rule in Cloudflare:${NC}"
                    echo "    Rules → Origin Rules → Create rule"
                    echo "    • Match: Hostname equals cdn.$input_domain"
                    echo "    • Action: Destination Port → Rewrite to 2082"
                    echo ""
                    echo -e "  See https://moav.sh/docs/DNS for detailed instructions."
                    echo ""
                    echo -e "  ${DIM}A BIND-format zone file is saved to outputs/dns-records.txt${NC}"
                    echo -e "  ${DIM}Import it in Cloudflare: DNS > Records > Import and Upload${NC}"
                    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
                    echo ""

                    # Ask user to confirm DNS is configured
                    if ! confirm "Have you configured DNS records (or will do so now)?" "y"; then
                        echo ""
                        warn "DNS must be configured before services will work properly."
                        echo "  You can configure DNS later and run 'moav bootstrap' again."
                        echo ""
                    fi
                else
                    # No domain - warn about disabled services
                    echo ""
                    warn "No domain provided!"
                    echo ""
                    echo -e "  ${YELLOW}Services that require a domain (will be disabled):${NC}"
                    echo "    • Trojan, AnyTLS, Hysteria2, CDN VLESS (need TLS certificates)"
                    echo "    • TrustTunnel"
                    echo "    • DNS tunnels (dnstt, Slipstream, MasterDNS, XDNS)"
                    echo ""
                    echo -e "  ${GREEN}Services that work without a domain:${NC}"
                    echo "    • Reality (VLESS) — uses dl.google.com for TLS camouflage"
                    echo "    • XHTTP (VLESS+Reality)"
                    echo "    • Shadowsocks-2022"
                    echo "    • WireGuard (direct UDP)"
                    echo "    • AmneziaWG (DPI-resistant WireGuard)"
                    echo "    • Telegram MTProxy (fake-TLS, IP only)"
                    echo "    • Admin dashboard (self-signed certificate)"
                    echo "    • Psiphon Conduit (bandwidth donation)"
                    echo "    • Tor Snowflake (bandwidth donation)"
                    echo ""

                    if confirm "Continue with domainless mode?" "y"; then
                        domainless_mode=true
                        # Disable cert-needing protocols. The TROJAN/HYSTERIA2/DNSTT/
                        # SLIPSTREAM/MASTERDNS/TRUSTTUNNEL set must match bootstrap.sh:
                        # 41-46. XDNS is added here so dns-router (in the dnstunnel
                        # profile) doesn't fight systemd-resolved for port 53 with
                        # nothing to route; direct-mode XDNS can be re-enabled manually.
                        for var in ENABLE_TROJAN ENABLE_ANYTLS ENABLE_HYSTERIA2 ENABLE_DNSTT ENABLE_SLIPSTREAM ENABLE_MASTERDNS ENABLE_XDNS ENABLE_TRUSTTUNNEL; do
                            update_env_var ".env" "$var" "false"
                        done
                        # Derive DEFAULT_PROFILES from the mutated ENABLE_* set (issue #106).
                        local _dl_profiles
                        _dl_profiles=$(derive_enabled_profiles ".env")
                        sed -i "s|^DEFAULT_PROFILES=.*|DEFAULT_PROFILES=\"${_dl_profiles}\"|" .env
                        success "Domain-less mode enabled"
                        info "Reality, XHTTP, Shadowsocks-2022, WireGuard, AmneziaWG, Telegram MTProxy, Admin, Conduit, and Snowflake will be available"
                    else
                        echo ""
                        info "Please enter a domain to use all services."
                        echo "  You can edit .env later and run 'moav bootstrap' again."
                        return 1
                    fi
                fi
                echo ""

                # Generate or ask for admin password
                if [[ "$domainless_mode" == "true" ]]; then
                    echo ""
                    echo "  (Admin will use self-signed certificate in domainless mode)"
                fi
                ensure_admin_password
            else
                missing=1
            fi
        else
            error ".env.example not found"
            missing=1
        fi
    fi

    # Check if Docker is running
    if command -v docker &> /dev/null; then
        if docker info &> /dev/null; then
            success "Docker daemon is running"
        else
            warn "Docker daemon is not running"
            if confirm "Start Docker now?"; then
                info "Starting Docker..."
                sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || true
                sleep 2
                if docker info &> /dev/null; then
                    success "Docker daemon started"
                else
                    error "Failed to start Docker daemon"
                    echo "  You may need to:"
                    echo "    1. Log out and back in (for group permissions)"
                    echo "    2. Run: sudo systemctl start docker"
                    missing=1
                fi
            else
                error "Docker daemon is required"
                echo "  Start with: sudo systemctl start docker"
                missing=1
            fi
        fi
    fi

    # Check optional dependencies
    if command -v qrencode &> /dev/null; then
        success "qrencode is installed (for QR codes)"
    else
        warn "qrencode not installed (needed for QR codes in user packages)"
        if confirm "Install qrencode now?"; then
            install_qrencode
        else
            echo "  You can install later with:"
            echo "    Linux (Debian/Ubuntu): sudo apt install qrencode"
            echo "    Linux (RHEL/Fedora):   sudo dnf install qrencode"
            echo "    macOS:                 brew install qrencode"
        fi
    fi

    if [[ $missing -eq 1 ]]; then
        echo ""
        error "Prerequisites check failed. Please fix the issues above."
        rm -f "$PREREQS_FILE" 2>/dev/null
        exit 1
    fi

    success "All prerequisites met!"
    # Mark prerequisites as checked
    touch "$PREREQS_FILE"

    # Offer to install globally if not already installed
    if ! is_installed; then
        echo ""
        if confirm "Install 'moav' command globally? (run from anywhere)" "y"; then
            do_install
        fi
    fi
}

prereqs_already_checked() {
    # Prerequisites must be re-checked if .env is missing
    [[ -f "$PREREQS_FILE" ]] && [[ -f ".env" ]]
}






doctor_check_net() {
    local rc=0
    nt_status || rc=$?
    # rc=2 → bundle not applied or kernel unsupported. Skip extended checks.
    [[ "$rc" -eq 2 ]] && return 2

    local pass=true
    [[ "$rc" -eq 1 ]] && pass=false
    nt_check_pmtu  || pass=false
    nt_check_drops || pass=false
    # CGNAT returns 2 (unknown — no route or RFC1918 without SERVER_IP), don't fail on that
    local cgnat=0; nt_check_cgnat || cgnat=$?
    [[ "$cgnat" -eq 1 ]] && pass=false
    nt_check_mtu   # informational only

    $pass && return 0 || return 1
}

doctor_is_enabled() {
    local value
    value=$(printf "%s" "${1:-}" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        true|1|yes|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

doctor_check_docker() {
    local pass=true

    # Docker daemon
    if command -v docker &>/dev/null; then
        local docker_ver
        docker_ver=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        if docker info &>/dev/null; then
            echo -e "    ${GREEN}✓${NC} Docker ${docker_ver} — running"
        else
            echo -e "    ${RED}✗${NC} Docker ${docker_ver} — daemon not running"
            echo -e "      ${DIM}Run: sudo systemctl start docker${NC}"
            pass=false
        fi
    else
        echo -e "    ${RED}✗${NC} Docker not installed"
        echo -e "      ${DIM}Install: curl -fsSL https://get.docker.com | sh${NC}"
        pass=false
    fi

    # Docker Compose
    if docker compose version &>/dev/null; then
        local compose_ver
        compose_ver=$(docker compose version --short 2>/dev/null)
        echo -e "    ${GREEN}✓${NC} Docker Compose ${compose_ver}"
    else
        echo -e "    ${RED}✗${NC} Docker Compose not found"
        pass=false
    fi

    # Docker disk usage (brief)
    local docker_usage
    docker_usage=$(docker system df --format '{{.Type}}\t{{.Size}}' 2>/dev/null)
    if [[ -n "$docker_usage" ]]; then
        local images_size containers_size volumes_size
        images_size=$(echo "$docker_usage" | grep "Images" | awk '{print $2}')
        volumes_size=$(echo "$docker_usage" | grep "Volumes" | awk '{print $2}')
        echo -e "    ${DIM}Docker disk: images=${images_size:-?}, volumes=${volumes_size:-?}${NC}"
    fi

    $pass && return 0 || return 1
}

doctor_check_memory() {
    local env_file="$SCRIPT_DIR/.env"

    # Get total and available memory in MB
    local total_mb available_mb
    total_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)
    available_mb=$(awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)

    if [[ -z "$total_mb" ]]; then
        echo -e "    ${YELLOW}○${NC} Could not read /proc/meminfo"
        return 2
    fi

    local total_gb
    total_gb=$(awk "BEGIN {printf \"%.1f\", $total_mb/1024}")
    local avail_gb
    avail_gb=$(awk "BEGIN {printf \"%.1f\", $available_mb/1024}")
    local used_pct
    used_pct=$(awk "BEGIN {printf \"%.0f\", ($total_mb-$available_mb)/$total_mb*100}")

    echo -e "    RAM: ${WHITE}${total_gb} GB${NC} total, ${available_mb} MB available (${used_pct}% used)"

    # Surface swap status on low-RAM hosts — missing swap is the usual reason
    # image builds get OOM-killed on a small VPS.
    local swap_mb
    swap_mb=$(awk '/SwapTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    if [[ "$total_mb" -le 2560 ]] && [[ "${swap_mb:-0}" -eq 0 ]]; then
        echo -e "    ${YELLOW}○${NC} No swap configured — image builds may be OOM-killed on low RAM"
        echo -e "      ${DIM}Add 2 GB swap: fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile${NC}"
        echo -e "      ${DIM}…and persist: echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab${NC}"
        echo -e "      ${DIM}Or build with limited parallelism: MOAV_BUILD_PARALLEL=1 moav build${NC}"
    fi

    # Check monitoring enabled
    local monitoring_enabled
    monitoring_enabled=$(get_env_val "ENABLE_MONITORING" "$env_file" "false")

    if [[ "$total_mb" -lt 1024 ]]; then
        echo -e "    ${RED}✗${NC} Less than 1 GB RAM — MoaV may be unstable"
        echo -e "      ${DIM}Upgrade to at least 1 GB (2 GB with monitoring)${NC}"
        return 1
    elif [[ "$total_mb" -lt 2048 ]] && [[ "$monitoring_enabled" == "true" ]]; then
        echo -e "    ${YELLOW}○${NC} Less than 2 GB with monitoring enabled — may cause hangs"
        echo -e "      ${DIM}Upgrade to 2 GB+ or disable monitoring: ENABLE_MONITORING=false${NC}"
        return 1
    elif [[ "$available_mb" -lt 256 ]]; then
        echo -e "    ${RED}✗${NC} Very low available memory (${available_mb} MB)"
        echo -e "      ${DIM}Check for memory leaks: docker stats --no-stream${NC}"
        return 1
    else
        echo -e "    ${GREEN}✓${NC} Memory OK"
        return 0
    fi
}

doctor_check_disk() {
    # Check root filesystem
    local disk_info
    disk_info=$(df -h / 2>/dev/null | tail -1)

    if [[ -z "$disk_info" ]]; then
        echo -e "    ${YELLOW}○${NC} Could not check disk space"
        return 2
    fi

    local total used avail pct
    total=$(echo "$disk_info" | awk '{print $2}')
    used=$(echo "$disk_info" | awk '{print $3}')
    avail=$(echo "$disk_info" | awk '{print $4}')
    pct=$(echo "$disk_info" | awk '{print $5}' | tr -d '%')

    echo -e "    Disk: ${WHITE}${total}${NC} total, ${avail} available (${pct}% used)"

    # Check /var/lib/docker separately if on different partition
    local docker_dir="/var/lib/docker"
    if [[ -d "$docker_dir" ]]; then
        local docker_disk
        docker_disk=$(df -h "$docker_dir" 2>/dev/null | tail -1)
        local docker_avail docker_pct
        docker_avail=$(echo "$docker_disk" | awk '{print $4}')
        docker_pct=$(echo "$docker_disk" | awk '{print $5}' | tr -d '%')
        # Only show if different from root
        local root_dev docker_dev
        root_dev=$(df / 2>/dev/null | tail -1 | awk '{print $1}')
        docker_dev=$(df "$docker_dir" 2>/dev/null | tail -1 | awk '{print $1}')
        if [[ "$root_dev" != "$docker_dev" ]]; then
            echo -e "    Docker: ${docker_avail} available (${docker_pct}% used)"
        fi
    fi

    # Thresholds
    local avail_mb
    avail_mb=$(df -m / 2>/dev/null | tail -1 | awk '{print $4}')

    if [[ "${avail_mb:-0}" -lt 1024 ]]; then
        echo -e "    ${RED}✗${NC} Less than 1 GB free disk space"
        echo -e "      ${DIM}Clean up: docker system prune -a --volumes${NC}"
        echo -e "      ${DIM}Find large files: apt install ncdu && ncdu /${NC}"
        return 1
    elif [[ "${avail_mb:-0}" -lt 2048 ]]; then
        echo -e "    ${YELLOW}○${NC} Less than 2 GB free — may run low with monitoring/logs"
        echo -e "      ${DIM}Check usage: ncdu / or docker system df -v${NC}"
        return 1
    else
        echo -e "    ${GREEN}✓${NC} Disk space OK"
        return 0
    fi
}

# Inspect container json-file logs and offer to truncate ones above a threshold.
# Pre-1.7.6 containers (and any container created before the x-logging anchor was
# applied) keep growing under Docker's unbounded default. Truncating in place
# zeros the file without disrupting the running service — Docker keeps writing
# to the same FD and the kernel reclaims the disk pages immediately.
doctor_check_logs() {
    local docker_dir="/var/lib/docker/containers"
    local sudo_prefix=""
    [[ $EUID -ne 0 ]] && sudo_prefix="sudo"

    if [[ ! -d "$docker_dir" ]]; then
        echo -e "    ${YELLOW}○${NC} ${docker_dir} not found (skipping log-size check)"
        return 2
    fi
    if ! $sudo_prefix test -r "$docker_dir" 2>/dev/null; then
        echo -e "    ${YELLOW}○${NC} Cannot read ${docker_dir} (need root)"
        return 2
    fi

    local threshold_mb=100
    # find -size +100M matches files strictly larger than 100 MB
    local oversized
    oversized=$($sudo_prefix find "$docker_dir" -maxdepth 2 -name '*-json.log' -size "+${threshold_mb}M" -printf '%s\t%p\n' 2>/dev/null | sort -rn)

    if [[ -z "$oversized" ]]; then
        echo -e "    ${GREEN}✓${NC} Container logs under ${threshold_mb} MB threshold"
        return 0
    fi

    # Build container ID → name map for nicer output
    declare -A name_map
    local map_line cid cname
    while IFS= read -r map_line; do
        cid=$(echo "$map_line" | awk '{print $1}')
        cname=$(echo "$map_line" | awk '{print $2}')
        [[ -n "$cid" ]] && name_map["$cid"]="$cname"
    done < <(docker ps -a --no-trunc --format '{{.ID}} {{.Names}}' 2>/dev/null || true)

    echo -e "    ${YELLOW}○${NC} Container logs over ${threshold_mb} MB (likely pre-rotation containers):"
    local count=0 total_bytes=0 size path id name size_mb
    while IFS=$'\t' read -r size path; do
        [[ -z "$size" ]] && continue
        ((count++)) || true
        total_bytes=$((total_bytes + size))
        id=$(basename "$(dirname "$path")")
        name="${name_map[$id]:-${id:0:12}}"
        size_mb=$((size / 1024 / 1024))
        echo -e "      ${DIM}${size_mb} MB  ${name}${NC}"
    done <<< "$oversized"

    local total_mb=$((total_bytes / 1024 / 1024))
    echo -e "    ${YELLOW}Total:${NC} ${total_mb} MB across ${count} log file(s)"

    # Only prompt when interactive (skip in cron / CI / piped doctor runs)
    if [[ ! -t 0 ]]; then
        echo -e "      ${DIM}Run interactively to truncate, or:${NC}"
        echo -e "      ${DIM}sudo truncate -s 0 /var/lib/docker/containers/*/*-json.log${NC}"
        return 1
    fi

    local confirm
    read -r -p "    Truncate these log files now? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "      ${DIM}Skipped. Manual: sudo truncate -s 0 /var/lib/docker/containers/*/*-json.log${NC}"
        return 1
    fi

    local truncated=0 failed=0
    while IFS=$'\t' read -r size path; do
        [[ -z "$path" ]] && continue
        if $sudo_prefix truncate -s 0 "$path" 2>/dev/null; then
            ((truncated++)) || true
        else
            ((failed++)) || true
        fi
    done <<< "$oversized"

    if [[ "$failed" -gt 0 ]]; then
        echo -e "    ${YELLOW}○${NC} Truncated ${truncated}/${count} log file(s); ${failed} failed (permission denied?)"
        return 1
    fi
    echo -e "    ${GREEN}✓${NC} Truncated ${truncated} log file(s) (~${total_mb} MB freed)"
    echo -e "      ${DIM}Tip: existing containers keep their old logging policy until recreated.${NC}"
    echo -e "      ${DIM}Run 'docker compose up -d --force-recreate' to apply the 10m × 3 rotation.${NC}"
    return 0
}

doctor_lookup_a_records() {
    local host="$1"

    if command -v dig >/dev/null 2>&1; then
        dig +short A "$host" 2>/dev/null | awk '/^[0-9]+\./ { print $1 }' | sort -u
        return 0
    fi

    if command -v getent >/dev/null 2>&1; then
        getent ahostsv4 "$host" 2>/dev/null | awk '{ print $1 }' | sort -u
        return 0
    fi

    if command -v host >/dev/null 2>&1; then
        host "$host" 2>/dev/null | awk '/ has address / { print $NF }' | sort -u
        return 0
    fi

    if command -v nslookup >/dev/null 2>&1; then
        nslookup "$host" 2>/dev/null | awk '
            /^Name: / { name_seen=1; next }
            name_seen && /^Address: / {
                gsub(/#.*/, "", $2)
                print $2
            }
        ' | awk '/^[0-9]+\./ { print $1 }' | sort -u
        return 0
    fi

    return 127
}

doctor_lookup_ns_records() {
    local host="$1"
    # Extract parent zone (e.g., t.bitchat.center -> bitchat.center)
    local parent_zone="${host#*.}"

    if command -v dig >/dev/null 2>&1; then
        # First try: query authoritative NS of parent zone
        # Subdomain NS delegation appears in AUTHORITY section, not ANSWER
        local auth_ns
        auth_ns=$(dig +short NS "$parent_zone" 2>/dev/null | head -1)
        if [[ -n "$auth_ns" ]]; then
            local result
            # Parse AUTHORITY section for NS records
            result=$(dig NS "$host" "@${auth_ns}" 2>/dev/null | awk '/^;; AUTHORITY SECTION:/,/^$/ { if ($4 == "NS") print $5 }' | sed 's/\.$//' | sed '/^$/d' | sort -u)
            if [[ -n "$result" ]]; then
                echo "$result"
                return 0
            fi
        fi
        # Fallback: try +short (works for zones where NS is in ANSWER section)
        dig +short NS "$host" 2>/dev/null | sed 's/\.$//' | sed '/^$/d' | sort -u
        return 0
    fi

    if command -v host >/dev/null 2>&1; then
        host -t NS "$host" 2>/dev/null | awk '/ name server / { print $NF }' | sed 's/\.$//' | sort -u
        return 0
    fi

    if command -v nslookup >/dev/null 2>&1; then
        nslookup -type=NS "$host" 2>/dev/null | awk -F' = ' '/nameserver = / { print $2 }' | sed 's/\.$//' | sort -u
        return 0
    fi

    return 127
}

doctor_lines_to_csv() {
    awk '
        NF {
            if (count++) {
                printf ", "
            }
            printf "%s", $0
        }
        END {
            if (count) {
                printf "\n"
            }
        }
    '
}

doctor_domainless_protocols() {
    local env_file="$1"
    local protocols=()

    if doctor_is_enabled "$(get_env_val "ENABLE_REALITY" "$env_file" "true")"; then
        protocols+=("Reality")
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_XHTTP" "$env_file" "true")"; then
        protocols+=("XHTTP")
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_WIREGUARD" "$env_file" "true")"; then
        protocols+=("WireGuard")
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_AMNEZIAWG" "$env_file" "true")"; then
        protocols+=("AmneziaWG")
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_TELEMT" "$env_file" "true")"; then
        protocols+=("Telegram MTProxy")
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_SS" "$env_file" "false")"; then
        protocols+=("Shadowsocks-2022")
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_ADMIN_UI" "$env_file" "true")"; then
        protocols+=("Admin Dashboard")
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_CONDUIT" "$env_file" "true")"; then
        protocols+=("Conduit")
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_SNOWFLAKE" "$env_file" "true")"; then
        protocols+=("Snowflake")
    fi

    if [[ ${#protocols[@]} -gt 0 ]]; then
        printf "%s\n" "${protocols[@]}" | doctor_lines_to_csv
    fi
}

doctor_check_a_record() {
    local label="$1"
    local host="$2"
    local expected_ip="$3"
    local remediation="$4"
    local resolved_ips=""

    if ! resolved_ips=$(doctor_lookup_a_records "$host"); then
        error "${label}: unable to query DNS for ${host}"
        echo "  Install 'dig', 'host', or 'nslookup', then rerun 'moav doctor dns'."
        return 1
    fi

    if [[ -z "$resolved_ips" ]]; then
        error "${label}: ${host} does not resolve"
        echo "  Fix: ${remediation}"
        return 1
    fi

    if printf "%s\n" "$resolved_ips" | grep -Fxq "$expected_ip"; then
        success "${label}: ${host} points to ${expected_ip}"
        return 0
    fi

    error "${label}: ${host} does not point to ${expected_ip}"
    echo "  Found: $(printf "%s\n" "$resolved_ips" | doctor_lines_to_csv)"
    echo "  Fix: ${remediation}"
    return 1
}

doctor_check_ns_record() {
    local label="$1"
    local host="$2"
    local expected_ns="$3"
    local remediation="$4"
    local resolved_ns=""

    if ! resolved_ns=$(doctor_lookup_ns_records "$host"); then
        error "${label}: unable to query NS records for ${host}"
        echo "  Install 'dig', 'host', or 'nslookup', then rerun 'moav doctor dns'."
        return 1
    fi

    if [[ -z "$resolved_ns" ]]; then
        error "${label}: ${host} has no NS delegation"
        echo "  Fix: ${remediation}"
        return 1
    fi

    if printf "%s\n" "$resolved_ns" | grep -Fxiq "$expected_ns"; then
        success "${label}: ${host} delegates to ${expected_ns}"
        return 0
    fi

    error "${label}: ${host} does not delegate to ${expected_ns}"
    echo "  Found: $(printf "%s\n" "$resolved_ns" | doctor_lines_to_csv)"
    echo "  Fix: ${remediation}"
    return 1
}

doctor_check_resolves() {
    local label="$1"
    local host="$2"
    local remediation="$3"
    local resolved_ips=""

    if ! resolved_ips=$(doctor_lookup_a_records "$host"); then
        error "${label}: unable to query DNS for ${host}"
        echo "  Install 'dig', 'host', or 'nslookup', then rerun 'moav doctor dns'."
        return 1
    fi

    if [[ -z "$resolved_ips" ]]; then
        error "${label}: ${host} does not resolve"
        echo "  Fix: ${remediation}"
        return 1
    fi

    success "${label}: ${host} resolves ($(printf "%s\n" "$resolved_ips" | doctor_lines_to_csv))"
    return 0
}

doctor_check_dns() {
    local env_file=".env"
    local failures=0
    local domain=""
    local server_ip=""
    local dnstt_enabled=false
    local slipstream_enabled=false
    local cdn_subdomain=""
    local cdn_domain=""
    local cdn_host=""

    if [[ ! -f "$env_file" ]]; then
        error ".env file not found"
        echo "  Run 'moav check' or copy '.env.example' to '.env' first."
        return 1
    fi

    domain=$(get_env_val "DOMAIN" "$env_file" "")
    if [[ -z "$domain" ]]; then
        warn "DOMAIN is empty; skipping DNS diagnostics (domainless mode)."
        local domainless_protocols=""
        domainless_protocols=$(doctor_domainless_protocols "$env_file")
        if [[ -n "$domainless_protocols" ]]; then
            echo "  Domainless-capable protocols enabled: ${domainless_protocols}"
        else
            echo "  No domainless-capable protocols are enabled in .env."
        fi
        return 2
    fi

    server_ip=$(get_env_val "SERVER_IP" "$env_file" "")
    if [[ -z "$server_ip" ]]; then
        server_ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)
        if [[ -n "$server_ip" ]]; then
            warn "SERVER_IP is empty in .env; using detected public IP for comparison: ${server_ip}"
        else
            error "SERVER_IP is empty and public IP detection failed"
            echo "  Set SERVER_IP in .env so A records can be verified."
            failures=$((failures + 1))
        fi
    else
        info "Expected server IP: ${server_ip}"
    fi

    if [[ -n "$server_ip" ]]; then
        if ! doctor_check_a_record "Main A record" "$domain" "$server_ip" "set A @ -> ${server_ip} (DNS only)"; then
            failures=$((failures + 1))
        fi
    fi

    if doctor_is_enabled "$(get_env_val "ENABLE_DNSTT" "$env_file" "true")"; then
        dnstt_enabled=true
    fi
    if doctor_is_enabled "$(get_env_val "ENABLE_SLIPSTREAM" "$env_file" "true")"; then
        slipstream_enabled=true
    fi

    local xdns_pre_enabled=""
    xdns_pre_enabled=$(get_env_val "ENABLE_XDNS" "$env_file" "true")

    local masterdns_pre_enabled=""
    masterdns_pre_enabled=$(get_env_val "ENABLE_MASTERDNS" "$env_file" "true")

    if [[ "$dnstt_enabled" == "true" || "$slipstream_enabled" == "true" || "$masterdns_pre_enabled" == "true" || "$xdns_pre_enabled" == "true" ]]; then
        local dns_host="dns.${domain}"
        if [[ -n "$server_ip" ]]; then
            if ! doctor_check_a_record "DNS nameserver A record" "$dns_host" "$server_ip" "set A dns -> ${server_ip} (DNS only)"; then
                failures=$((failures + 1))
            fi
        else
            warn "Skipping dns.${domain} A record comparison until SERVER_IP is configured."
        fi

        if [[ "$dnstt_enabled" == "true" ]]; then
            local dnstt_subdomain=""
            dnstt_subdomain=$(get_env_val "DNSTT_SUBDOMAIN" "$env_file" "t")
            if ! doctor_check_ns_record "dnstt NS record" "${dnstt_subdomain}.${domain}" "$dns_host" "set NS ${dnstt_subdomain} -> ${dns_host}"; then
                failures=$((failures + 1))
            fi
        fi

        if [[ "$slipstream_enabled" == "true" ]]; then
            local slipstream_subdomain=""
            slipstream_subdomain=$(get_env_val "SLIPSTREAM_SUBDOMAIN" "$env_file" "s")
            if ! doctor_check_ns_record "Slipstream NS record" "${slipstream_subdomain}.${domain}" "$dns_host" "set NS ${slipstream_subdomain} -> ${dns_host}"; then
                failures=$((failures + 1))
            fi
        fi

        local masterdns_enabled=""
        masterdns_enabled=$(get_env_val "ENABLE_MASTERDNS" "$env_file" "true")
        if [[ "$masterdns_enabled" == "true" ]]; then
            local masterdns_subdomain masterdns_public_sub
            masterdns_subdomain=$(get_env_val "MASTERDNS_SUBDOMAIN" "$env_file" "m")
            masterdns_public_sub=$(get_env_val "MASTERDNS_PUBLIC_SUBDOMAIN" "$env_file" "")
            if ! doctor_check_ns_record "MasterDNS NS record" "${masterdns_subdomain}.${domain}" "$dns_host" "set NS ${masterdns_subdomain} -> ${dns_host}"; then
                failures=$((failures + 1))
            fi
            # dns-router still serves the base subdomain and pre-existing bundles use it,
            # so when a public alias is set both delegations must exist
            if [[ -n "$masterdns_public_sub" && "$masterdns_public_sub" != "$masterdns_subdomain" ]]; then
                if ! doctor_check_ns_record "MasterDNS public NS record" "${masterdns_public_sub}.${domain}" "$dns_host" "set NS ${masterdns_public_sub} -> ${dns_host}"; then
                    failures=$((failures + 1))
                fi
            fi
        fi

        local xdns_enabled=""
        xdns_enabled=$(get_env_val "ENABLE_XDNS" "$env_file" "true")
        if [[ "$xdns_enabled" == "true" ]]; then
            local xdns_subdomain=""
            xdns_subdomain=$(get_env_val "XDNS_SUBDOMAIN" "$env_file" "x")
            if ! doctor_check_ns_record "XDNS NS record" "${xdns_subdomain}.${domain}" "$dns_host" "set NS ${xdns_subdomain} -> ${dns_host}"; then
                failures=$((failures + 1))
            fi
        fi
    else
        info "DNS tunnel checks skipped: dnstt, Slipstream, MasterDNS, and XDNS are all disabled."
    fi

    cdn_subdomain=$(get_env_val "CDN_SUBDOMAIN" "$env_file" "")
    cdn_domain=$(get_env_val "CDN_DOMAIN" "$env_file" "")
    if [[ -n "$cdn_subdomain" ]]; then
        cdn_host="${cdn_subdomain}.${domain}"
    elif [[ -n "$cdn_domain" ]]; then
        cdn_host="$cdn_domain"
    fi

    if [[ -n "$cdn_host" ]]; then
        if ! doctor_check_resolves "CDN endpoint" "$cdn_host" "create or fix the CDN DNS entry for ${cdn_host}"; then
            failures=$((failures + 1))
        fi
    else
        info "CDN check skipped: CDN_SUBDOMAIN/CDN_DOMAIN is not configured."
    fi

    if [[ $failures -gt 0 ]]; then
        echo ""
        echo "See https://moav.sh/docs/DNS for record templates and provider-specific examples."
        # Generate zone file for easy import
        local zone_file
        zone_file=$(generate_dns_zone_file 2>/dev/null)
        if [[ -n "$zone_file" ]] && [[ -f "$zone_file" ]]; then
            echo ""
            success "DNS zone file saved to: $zone_file"
            echo -e "  ${DIM}Import into Cloudflare: DNS > Records > Import and Upload${NC}"
            echo ""
            if confirm "Show zone file contents?" "y"; then
                echo ""
                cat "$zone_file"
                echo ""
            fi
        fi
        return 1
    fi

    # Generate zone file even on success (for reference)
    generate_dns_zone_file >/dev/null 2>&1

    return 0
}

doctor_check_services() {
    local env_file="$SCRIPT_DIR/.env"
    local pass=true

    # Map of ENABLE_* vars to service names
    local -A service_map=(
        ["ENABLE_REALITY"]="sing-box"
        ["ENABLE_SS"]="sing-box"
        ["ENABLE_XHTTP"]="xray"
        ["ENABLE_WIREGUARD"]="wireguard"
        ["ENABLE_AMNEZIAWG"]="amneziawg"
        ["ENABLE_TELEMT"]="telemt"
        ["ENABLE_DNSTT"]="dnstt"
        ["ENABLE_SLIPSTREAM"]="slipstream"
        ["ENABLE_TRUSTTUNNEL"]="trusttunnel"
        ["ENABLE_CONDUIT"]="psiphon-conduit"
        ["ENABLE_SNOWFLAKE"]="snowflake"
    )

    local running_services
    running_services=$(docker compose ps --services --filter "status=running" 2>/dev/null || echo "")
    local restarting_services
    restarting_services=$(docker compose ps --services --filter "status=restarting" 2>/dev/null || echo "")

    for enable_var in "${!service_map[@]}"; do
        local svc="${service_map[$enable_var]}"
        local enabled
        enabled=$(get_env_val "$enable_var" "$env_file" "true")

        if [[ "$enabled" == "true" ]]; then
            if echo "$restarting_services" | grep -qw "$svc"; then
                echo -e "    ${RED}✗${NC} $svc — enabled but crash-looping (restarting)"
                echo -e "      ${DIM}Check logs: moav logs $svc${NC}"
                pass=false
            elif echo "$running_services" | grep -qw "$svc"; then
                echo -e "    ${GREEN}✓${NC} $svc — running"
            else
                echo -e "    ${YELLOW}○${NC} $svc — enabled but not running"
                echo -e "      ${DIM}Start with: moav start${NC}"
                pass=false
            fi
        fi
    done

    $pass && return 0 || return 1
}

doctor_check_config() {
    local pass=true
    local env_file="$SCRIPT_DIR/.env"

    # Check bootstrap has been run
    local bootstrapped=false
    docker run --rm -v moav_moav_state:/state alpine test -f /state/.bootstrapped 2>/dev/null && bootstrapped=true

    if [[ "$bootstrapped" != "true" ]]; then
        echo -e "    ${RED}✗${NC} Bootstrap has not been run"
        echo -e "      ${DIM}Run: moav bootstrap${NC}"
        return 1
    fi
    echo -e "    ${GREEN}✓${NC} Bootstrap completed"

    # Check config files for enabled services
    local -A config_files=(
        ["ENABLE_REALITY"]="configs/sing-box/config.json"
        ["ENABLE_XHTTP"]="configs/xray/config.json"
        ["ENABLE_WIREGUARD"]="configs/wireguard/wg0.conf"
        ["ENABLE_AMNEZIAWG"]="configs/amneziawg/awg0.conf"
        ["ENABLE_TELEMT"]="configs/telemt/config.toml"
    )

    for enable_var in "${!config_files[@]}"; do
        local enabled
        enabled=$(get_env_val "$enable_var" "$env_file" "true")
        local config="${config_files[$enable_var]}"
        local svc_name="${config%%/*}"
        svc_name="${svc_name#configs/}"

        if [[ "$enabled" == "true" ]]; then
            if [[ -f "$SCRIPT_DIR/$config" ]]; then
                echo -e "    ${GREEN}✓${NC} $config exists"
            else
                echo -e "    ${RED}✗${NC} $config missing"
                echo -e "      ${DIM}Run: moav bootstrap${NC}"
                pass=false
            fi
        fi
    done

    # Check state keys
    local keys_exist=false
    docker run --rm -v moav_moav_state:/state alpine test -d /state/keys 2>/dev/null && keys_exist=true
    if [[ "$keys_exist" == "true" ]]; then
        echo -e "    ${GREEN}✓${NC} State keys directory exists"
    else
        echo -e "    ${RED}✗${NC} State keys missing"
        echo -e "      ${DIM}Run: moav bootstrap${NC}"
        pass=false
    fi

    # Per-service state key checks: ENABLE_X=true but keys missing = service will crash-loop
    # Each entry: "ENABLE_VAR:service_name:key_path1,key_path2,..."
    local state_key_specs=(
        "ENABLE_DNSTT:dnstt:/state/keys/dnstt-server.key.hex,/state/keys/dnstt-server.pub.hex"
        "ENABLE_SLIPSTREAM:slipstream:/state/keys/slipstream-cert.pem,/state/keys/slipstream-key.pem"
        "ENABLE_WIREGUARD:wireguard:/state/keys/wg-server.key,/state/keys/wg-server.pub"
        "ENABLE_AMNEZIAWG:amneziawg:/state/keys/awg-server.key,/state/keys/awg-server.pub"
    )
    for spec in "${state_key_specs[@]}"; do
        local var="${spec%%:*}"
        local rest="${spec#*:}"
        local svc="${rest%%:*}"
        local paths="${rest#*:}"
        local default="true"
        [[ "$var" == "ENABLE_XDNS" ]] && default="true"
        local enabled
        enabled=$(get_env_val "$var" "$env_file" "$default")
        [[ "$enabled" != "true" ]] && continue

        local missing=""
        IFS=',' read -ra path_list <<< "$paths"
        for p in "${path_list[@]}"; do
            if ! docker run --rm -v moav_moav_state:/state alpine test -f "$p" 2>/dev/null; then
                missing+="${p##*/} "
            fi
        done
        if [[ -n "$missing" ]]; then
            echo -e "    ${RED}✗${NC} $svc enabled but missing key(s): ${missing% }"
            echo -e "      ${DIM}Run: moav bootstrap   (regenerates missing keys idempotently)${NC}"
            pass=false
        else
            echo -e "    ${GREEN}✓${NC} $svc keys present"
        fi
    done

    $pass && return 0 || return 1
}

doctor_check_ports() {
    local env_file="$SCRIPT_DIR/.env"
    local pass=true

    # Service -> port mappings
    local -A port_map=(
        ["sing-box"]="$(get_env_val 'PORT_REALITY' "$env_file" '443')"
        ["xray"]="$(get_env_val 'PORT_XHTTP' "$env_file" '2096')"
        ["wireguard"]="$(get_env_val 'PORT_WIREGUARD' "$env_file" '51820')"
        ["amneziawg"]="$(get_env_val 'PORT_AMNEZIAWG' "$env_file" '51821')"
        ["telemt"]="$(get_env_val 'PORT_TELEMT' "$env_file" '993')"
        ["trusttunnel"]="$(get_env_val 'PORT_TRUSTTUNNEL' "$env_file" '4443')"
        ["admin"]="$(get_env_val 'PORT_ADMIN' "$env_file" '9443')"
        ["grafana"]="$(get_env_val 'PORT_GRAFANA' "$env_file" '9444')"
    )

    # Check port 53 availability for any enabled DNS tunnel
    local dnstt_enabled slip_enabled xdns_enabled masterdns_enabled
    dnstt_enabled=$(get_env_val "ENABLE_DNSTT" "$env_file" "true")
    slip_enabled=$(get_env_val "ENABLE_SLIPSTREAM" "$env_file" "true")
    masterdns_enabled=$(get_env_val "ENABLE_MASTERDNS" "$env_file" "true")
    xdns_enabled=$(get_env_val "ENABLE_XDNS" "$env_file" "true")

    if [[ "$dnstt_enabled" == "true" || "$slip_enabled" == "true" || "$masterdns_enabled" == "true" || "$xdns_enabled" == "true" ]]; then
        if port53_conflict_detected; then
            if systemctl is-active systemd-resolved &>/dev/null; then
                echo -e "    ${RED}✗${NC} Port 53 in use by systemd-resolved (DNS tunnels need it)"
                echo -e "      ${DIM}Run: moav setup-dns${NC}"
                pass=false
            else
                echo -e "    ${YELLOW}○${NC} Port 53 in use — DNS tunnels may fail to bind"
            fi
        elif ss -ulnp 2>/dev/null | grep -q ':53 ' || netstat -ulnp 2>/dev/null | grep -q ':53 '; then
            echo -e "    ${GREEN}✓${NC} Port 53 bound by MoaV dns-router"
        else
            echo -e "    ${GREEN}✓${NC} Port 53 available for DNS tunnels"
        fi
    fi

    # Check key service ports
    for svc in "${!port_map[@]}"; do
        local port="${port_map[$svc]}"
        if ss -tlnp 2>/dev/null | grep -q ":${port} " || ss -ulnp 2>/dev/null | grep -q ":${port} "; then
            echo -e "    ${GREEN}✓${NC} Port $port ($svc) — listening"
        else
            echo -e "    ${DIM}○${NC} Port $port ($svc) — not listening"
        fi
    done

    $pass && return 0 || return 1
}

doctor_check_conflicts() {
    local pass=true
    local enabled running
    enabled=$(dns_tunnels_enabled)
    running=$(dns_tunnels_running)

    # 1) Report enabled tunnels (all can coexist via dns-router)
    if [[ -n "$enabled" ]]; then
        echo -e "    ${GREEN}✓${NC} DNS tunnel(s) enabled: $enabled"
    else
        echo -e "    ${DIM}○${NC} No DNS tunnel enabled"
    fi

    # 2) Config vs runtime drift: a disabled tunnel has containers running
    for t in $running; do
        if ! echo " $enabled " | grep -q " $t "; then
            local svcs
            svcs=$(dns_tunnel_field "$t" services)
            echo -e "    ${YELLOW}!${NC} $t is running but disabled in .env"
            echo -e "      ${DIM}Stop: docker compose stop $svcs${NC}"
            pass=false
        fi
    done

    # 4) dns-router crash loop — port 53 taken by another process, or misconfigured backend
    local restarting
    restarting=$(docker compose ps --services --filter "status=restarting" 2>/dev/null || echo "")
    if echo "$restarting" | grep -qw "dns-router"; then
        echo -e "    ${RED}✗${NC} dns-router is crash-looping"
        echo -e "      ${DIM}Check: port 53 may be taken by another process, or a *_DOMAIN env var is unset${NC}"
        echo -e "      ${DIM}Fix: moav doctor env — then docker compose logs dns-router${NC}"
        pass=false
    fi

    $pass && return 0 || return 1
}

# Reality dest reachability (#115). Uses the container's resolver (matches what
# Reality sees at handshake); falls back to host resolver when container down.
doctor_check_reality() {
    local env_file="$SCRIPT_DIR/.env"
    local enable_reality enable_xhttp
    enable_reality=$(get_env_val "ENABLE_REALITY" "$env_file" "true")
    enable_xhttp=$(get_env_val "ENABLE_XHTTP" "$env_file" "true")

    if [[ "$enable_reality" != "true" && "$enable_xhttp" != "true" ]]; then
        echo -e "    ${DIM}○${NC} Reality and XHTTP-Reality both disabled — skipping"
        return 2
    fi

    local pass=true
    _doctor_reality_tcp_probe() {
        local container="$1" host="$2" port="$3"
        docker compose exec -T "$container" sh -s -- "$host" "$port" <<'EOF'
host="$1"
port="$2"

if command -v nc >/dev/null 2>&1 && nc -z -w 5 "$host" "$port" >/dev/null 2>&1; then
    exit 0
fi

if command -v curl >/dev/null 2>&1 && curl -k -IsS --connect-timeout 5 --max-time 8 "https://$host:$port/" >/dev/null 2>&1; then
    exit 0
fi

if command -v bash >/dev/null 2>&1 && timeout 5 bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1; then
    exit 0
fi

exit 1
EOF
    }

    _doctor_reality_one() {
        local label="$1" container="$2" key="$3" default_target="$4"
        local host_port host port resolver_label resolves=false container_running=false
        host_port=$(get_env_val "$key" "$env_file" "$default_target")
        host="${host_port%%:*}"
        port="${host_port##*:}"
        [[ "$port" == "$host_port" ]] && port=443  # no `:port` in value

        if docker compose ps --status running --services 2>/dev/null | grep -qw "$container"; then
            container_running=true
            resolver_label="container $container"
            if docker compose exec -T "$container" getent hosts "$host" >/dev/null 2>&1; then
                resolves=true
            fi
        else
            resolver_label="host (container $container not running)"
            reality_target_resolves "$host" && resolves=true
        fi

        if [[ "$resolves" != "true" ]]; then
            echo -e "    ${RED}✗${NC} $label: $host does NOT resolve ($resolver_label)"
            echo -e "      ${DIM}NXDOMAIN — Reality fallback fails, inbound RSTs every TLS hello (issue #115).${NC}"
            echo -e "      ${DIM}Fix: set $key in .env to a resolvable host. See: moav doctor reality --help${NC}"
            pass=false
            return
        fi

        if [[ "$container_running" == "true" ]]; then
            if _doctor_reality_tcp_probe "$container" "$host" "$port"; then
                echo -e "    ${GREEN}✓${NC} $label: $host:$port resolves and reachable from $container"
            else
                echo -e "    ${YELLOW}!${NC} $label: $host resolves but TCP $port unreachable from $container"
                echo -e "      ${DIM}Reality fallback will hang or RST. Check container egress / VPS firewall.${NC}"
                pass=false
            fi
        else
            echo -e "    ${GREEN}✓${NC} $label: $host resolves ($resolver_label, TCP probe skipped)"
        fi
    }

    [[ "$enable_reality" == "true" ]] && _doctor_reality_one "VLESS Reality (:443)" "sing-box" "REALITY_TARGET" "www.cloudflare.com:443"
    [[ "$enable_xhttp"    == "true" ]] && _doctor_reality_one "XHTTP-Reality (:2096)" "xray" "XHTTP_REALITY_TARGET" "www.cloudflare.com:443"

    unset -f _doctor_reality_tcp_probe
    unset -f _doctor_reality_one
    $pass && return 0 || return 1
}

doctor_check_env() {
    local env_file="$SCRIPT_DIR/.env"
    local example_file="$SCRIPT_DIR/.env.example"
    local pass=true

    if [[ ! -f "$env_file" ]]; then
        echo -e "    ${RED}✗${NC} .env file not found"
        echo -e "      ${DIM}Run: cp .env.example .env${NC}"
        return 1
    fi

    if [[ ! -f "$example_file" ]]; then
        echo -e "    ${YELLOW}○${NC} .env.example not found — skipping comparison"
        return 2
    fi

    # Extract variable names from .env.example (skip comments and empty lines)
    local missing=0
    local total=0
    local critical_missing=()

    # Critical variables that should always be set
    local critical_vars=("ADMIN_PASSWORD" "DOMAIN" "SERVER_IP")

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue
        [[ ! "$line" =~ = ]] && continue

        local var_name="${line%%=*}"
        var_name=$(echo "$var_name" | xargs)  # trim whitespace
        [[ -z "$var_name" ]] && continue

        total=$((total + 1))

        if ! grep -q "^${var_name}=" "$env_file" 2>/dev/null; then
            missing=$((missing + 1))
            # Check if critical
            for cv in "${critical_vars[@]}"; do
                if [[ "$var_name" == "$cv" ]]; then
                    critical_missing+=("$var_name")
                fi
            done
        fi
    done < "$example_file"

    if [[ ${#critical_missing[@]} -gt 0 ]]; then
        for cv in "${critical_missing[@]}"; do
            echo -e "    ${RED}✗${NC} Missing critical variable: $cv"
        done
        pass=false
    fi

    if [[ $missing -gt 0 ]]; then
        echo -e "    ${YELLOW}○${NC} $missing of $total variables from .env.example not in .env"
        echo -e "      ${DIM}New variables use defaults. Review with: diff <(grep -o '^[A-Z_]*=' .env.example | sort) <(grep -o '^[A-Z_]*=' .env | sort)${NC}"
    else
        echo -e "    ${GREEN}✓${NC} All $total variables from .env.example present in .env"
    fi

    $pass && return 0 || return 1
}

doctor_check_updates() {
    local current_version
    current_version=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")

    echo -e "    Current version: ${WHITE}v${current_version}${NC}"

    # Check latest version from GitHub
    local latest
    latest=$(curl -sf --max-time 5 "https://api.github.com/repos/MotherofallVPNs/moav/releases/latest" 2>/dev/null | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4 | sed 's/^v//')

    if [[ -z "$latest" ]]; then
        echo -e "    ${YELLOW}○${NC} Could not check for updates (no internet or GitHub unreachable)"
        return 2
    fi

    if [[ "$current_version" == "$latest" ]]; then
        echo -e "    ${GREEN}✓${NC} Up to date (v${latest})"
        return 0
    elif version_gt "$latest" "$current_version"; then
        echo -e "    ${YELLOW}○${NC} Update available: v${latest} (current: v${current_version})"
        echo -e "      ${DIM}Run: moav update${NC}"
        return 1
    else
        # Running ahead of the latest published release — e.g. a dev/pre-release
        # build, or the latest GitHub release tag lags the shipped VERSION.
        echo -e "    ${GREEN}✓${NC} Running v${current_version} (ahead of latest release v${latest})"
        return 0
    fi
}

# Registry of diagnostic checks: "<name>:<description>" -> doctor_check_<name>.
# Lives with cmd_doctor (it was briefly carried along by the nettune extraction).
DOCTOR_CHECKS=(
    "docker:Check Docker and prerequisites"
    "memory:Check available RAM"
    "disk:Check available disk space"
    "logs:Check container log file sizes (offers to truncate oversized)"
    "dns:Check DNS records for enabled protocols"
    "services:Check running services vs enabled config"
    "config:Check config files and keys from bootstrap"
    "ports:Check required ports are available"
    "conflicts:Check for conflicting services (e.g. DNS tunnels on port 53)"
    "reality:Check Reality fallback targets resolve and are reachable"
    "net:Check BBR/sysctl tuning + packet drops + PMTU + CGNAT + MTU"
    "peers:Check for duplicate WireGuard/AmneziaWG peer addresses (--fix repairs)"
    "env:Compare .env with .env.example for missing vars"
    "updates:Check for MoaV updates"
)

cmd_doctor() {
    local requested_check="${1:-}"
    # `moav doctor peers --fix [--yes]` — the only check that can repair what
    # it finds. Deliberately not a blanket `doctor --fix`: the repair rotates
    # peer addresses and keys, which invalidates those users' existing bundles.
    if [[ "$requested_check" == "peers" ]] && [[ "${2:-}" == "--fix" ]]; then
        print_section "Repair duplicate peer addresses"
        peers_report || true
        peers_repair "${3:-}"
        return $?
    fi
    local selected_checks=()
    local check_spec=""
    local check_name=""
    local check_desc=""
    local found=false
    local passed=0
    local failed=0
    local skipped=0
    local rc=0

    case "$requested_check" in
        help|--help|-h)
            echo "Usage: moav doctor [check]"
            echo ""
            echo "Run MoaV diagnostic checks."
            echo ""
            echo "Checks:"
            for check_spec in "${DOCTOR_CHECKS[@]}"; do
                check_name="${check_spec%%:*}"
                check_desc="${check_spec#*:}"
                printf "  %-12s %s\n" "$check_name" "$check_desc"
            done
            echo ""
            echo "Examples:"
            echo "  moav doctor"
            echo "  moav doctor dns"
            return 0
            ;;
    esac

    for check_spec in "${DOCTOR_CHECKS[@]}"; do
        check_name="${check_spec%%:*}"
        if [[ -z "$requested_check" || "$requested_check" == "all" || "$requested_check" == "$check_name" ]]; then
            selected_checks+=("$check_spec")
        fi
        if [[ -n "$requested_check" && "$requested_check" == "$check_name" ]]; then
            found=true
        fi
    done

    if [[ -n "$requested_check" && "$requested_check" != "all" && "$found" != "true" ]]; then
        error "Unknown doctor check: ${requested_check}"
        echo ""
        cmd_doctor --help
        return 1
    fi

    print_section "MoaV Doctor"
    info "Running ${#selected_checks[@]} diagnostic check(s)..."

    for check_spec in "${selected_checks[@]}"; do
        check_name="${check_spec%%:*}"
        check_desc="${check_spec#*:}"

        echo ""
        echo -e "${WHITE}${check_name}${NC} - ${check_desc}"

        if "doctor_check_${check_name}"; then
            passed=$((passed + 1))
        else
            rc=$?
            case "$rc" in
                2)
                    skipped=$((skipped + 1))
                    ;;
                *)
                    failed=$((failed + 1))
                    ;;
            esac
        fi
    done

    echo ""
    print_section "Doctor Summary"
    success "${passed} check(s) passed"
    if [[ $skipped -gt 0 ]]; then
        warn "${skipped} check(s) skipped"
    fi
    if [[ $failed -gt 0 ]]; then
        error "${failed} check(s) failed"
        return 1
    fi

    success "Doctor completed without failures."
}

# =============================================================================
# Service Management
# =============================================================================

get_running_services() {
    docker compose ps --services --filter "status=running" 2>/dev/null || echo ""
}

show_versions() {
    local singbox_ver wstunnel_ver conduit_ver snowflake_ver slipstream_ver telemt_ver
    local trusttunnel_ver trusttunnel_client_ver awgtools_ver xray_ver dnstt_ver
    singbox_ver=$(get_component_version "SINGBOX_VERSION" "1.13.12")
    wstunnel_ver=$(get_component_version "WSTUNNEL_VERSION" "10.6.1")
    conduit_ver=$(get_component_version "CONDUIT_VERSION" "1.2.0")
    snowflake_ver=$(get_component_version "SNOWFLAKE_VERSION" "latest")
    slipstream_ver=$(get_component_version "SLIPSTREAM_VERSION" "2026.02.22.1")
    telemt_ver=$(get_component_version "TELEMT_VERSION" "3.4.23")
    trusttunnel_ver=$(get_component_version "TRUSTTUNNEL_VERSION" "")
    trusttunnel_client_ver=$(get_component_version "TRUSTTUNNEL_CLIENT_VERSION" "")
    awgtools_ver=$(get_component_version "AWGTOOLS_VERSION" "")
    xray_ver=$(get_component_version "XRAY_VERSION" "v26.6.27")
    dnstt_ver=$(get_component_version "DNSTT_VERSION" "latest")

    echo ""
    echo -e "${CYAN}MoaV${NC} v${VERSION}"
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${WHITE}Component Versions:${NC}"
    echo ""
    echo -e "  ${CYAN}┌──────────────────┬────────────────┬──────────────────────────────────────────┐${NC}"
    echo -e "  ${CYAN}│${NC} ${WHITE}Component${NC}        ${CYAN}│${NC} ${WHITE}Version${NC}        ${CYAN}│${NC} ${WHITE}Source${NC}                                   ${CYAN}│${NC}"
    echo -e "  ${CYAN}├──────────────────┼────────────────┼──────────────────────────────────────────┤${NC}"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "sing-box" "$singbox_ver" "github.com/SagerNet/sing-box"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "wstunnel" "$wstunnel_ver" "github.com/erebe/wstunnel"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "trusttunnel" "$trusttunnel_ver" "github.com/TrustTunnel/TrustTunnel"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "trusttunnel-cli" "$trusttunnel_client_ver" "github.com/TrustTunnel/TrustTunnelClient"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "amneziawg" "$awgtools_ver" "github.com/amnezia-vpn/amneziawg-tools"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "conduit" "$conduit_ver" "github.com/Psiphon-Inc/conduit"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "snowflake" "$snowflake_ver" "torproject.org (built from src)"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "dnstt" "$dnstt_ver" "bamsoftware.com (built from src)"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "slipstream" "$slipstream_ver" "github.com/Mygod/slipstream-rust"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "telemt" "$telemt_ver" "github.com/telemt/telemt"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "xray-core" "$xray_ver" "github.com/XTLS/Xray-core"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${DIM}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "wireguard" "alpine" "wireguard-tools package"
    echo -e "  ${CYAN}└──────────────────┴────────────────┴──────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${DIM}Versions can be changed in .env and rebuilt with: moav build${NC}"
    echo ""
}

show_status() {
    # Get all defined services from docker-compose
    local all_services
    all_services=$(docker compose --profile all config --services 2>/dev/null | sort)

    # Get service status from docker compose (including stopped with -a)
    local raw_status json_lines
    raw_status=$(docker compose --profile all ps -a --format json 2>/dev/null)

    # Read ENABLE_* settings to determine which services are disabled
    local env_file="$SCRIPT_DIR/.env"
    declare -A disabled_services

    if [[ -f "$env_file" ]]; then
        local enable_reality=$(get_env_val "ENABLE_REALITY" "$env_file" "true")
        local enable_trojan=$(get_env_val "ENABLE_TROJAN" "$env_file" "true")
        local enable_anytls=$(get_env_val "ENABLE_ANYTLS" "$env_file" "false")
        local enable_hysteria2=$(get_env_val "ENABLE_HYSTERIA2" "$env_file" "true")
        local enable_wireguard=$(get_env_val "ENABLE_WIREGUARD" "$env_file" "true")
        local enable_dnstt=$(get_env_val "ENABLE_DNSTT" "$env_file" "true")
        local enable_admin=$(get_env_val "ENABLE_ADMIN_UI" "$env_file" "true")

        # Mark services as disabled based on ENABLE_* settings
        # sing-box handles Reality, Trojan, AnyTLS, Hysteria2
        if [[ "$enable_reality" != "true" ]] && [[ "$enable_trojan" != "true" ]] && [[ "$enable_anytls" != "true" ]] && [[ "$enable_hysteria2" != "true" ]]; then
            disabled_services["sing-box"]=1
            disabled_services["decoy"]=1
        fi
        [[ "$enable_wireguard" != "true" ]] && disabled_services["wireguard"]=1 && disabled_services["wstunnel"]=1
        local enable_slipstream=$(get_env_val "ENABLE_SLIPSTREAM" "$env_file" "true")
        [[ "$enable_dnstt" != "true" ]] && disabled_services["dnstt"]=1
        [[ "$enable_slipstream" != "true" ]] && disabled_services["slipstream"]=1
        # dns-router is disabled if both dnstt and slipstream are disabled
        if [[ "$enable_dnstt" != "true" ]] && [[ "$enable_slipstream" != "true" ]]; then
            disabled_services["dns-router"]=1
        fi
        [[ "$enable_admin" != "true" ]] && disabled_services["admin"]=1
        local enable_telemt=$(get_env_val "ENABLE_TELEMT" "$env_file" "true")
        [[ "$enable_telemt" != "true" ]] && disabled_services["telemt"]=1
    fi

    print_section "Service Status"
    echo ""
    echo -e "  ${CYAN}┌──────────────────────┬──────────────┬─────────────────────┬──────────────┬─────────────────┐${NC}"
    echo -e "  ${CYAN}│${NC} ${WHITE}Service${NC}              ${CYAN}│${NC} ${WHITE}Status${NC}       ${CYAN}│${NC} ${WHITE}Last Run${NC}            ${CYAN}│${NC} ${WHITE}Uptime${NC}       ${CYAN}│${NC} ${WHITE}Ports${NC}           ${CYAN}│${NC}"
    echo -e "  ${CYAN}├──────────────────────┼──────────────┼─────────────────────┼──────────────┼─────────────────┤${NC}"

    # Track which services we've displayed
    declare -A displayed_services

    # Handle both JSON array format and NDJSON (one object per line)
    if [[ -n "$raw_status" ]] && [[ "$raw_status" != "[]" ]]; then
        if [[ "$raw_status" == "["* ]]; then
            # Convert JSON array to one object per line (split on },{ )
            json_lines=$(echo "$raw_status" | sed 's/^\[//;s/\]$//;s/},{/}\n{/g')
        else
            json_lines="$raw_status"
        fi

        # Parse JSON and display each service (using here-string to avoid subshell)
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue

            local name service state ports health status_str created_at uptime last_run finished_at
            # Parse JSON fields (handle both "Key":"value" and "Key": "value" formats)
            name=$(echo "$line" | grep -oE '"Name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
            service=$(echo "$line" | grep -oE '"Service"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
            state=$(echo "$line" | grep -oE '"State"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
            health=$(echo "$line" | grep -oE '"Health"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
            status_str=$(echo "$line" | grep -oE '"Status"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
            created_at=$(echo "$line" | grep -oE '"CreatedAt"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
            ports=$(echo "$line" | grep -o '"Publishers":\[[^]]*\]' | grep -o '"PublishedPort":[0-9]*' | cut -d':' -f2 | sort -u | grep -v '^0$' | tr '\n' ',' | sed 's/,$//' || true)

            [[ -z "$name" ]] && continue

            # If Service field is missing, try to find matching service from all_services
            if [[ -z "$service" ]]; then
                local stripped="${name#moav-}"
                # Check if any service name contains or matches the stripped container name
                while IFS= read -r candidate; do
                    [[ -z "$candidate" ]] && continue
                    # Match: "psiphon-conduit" contains "conduit", or "sing-box" == "sing-box"
                    if [[ "$candidate" == *"$stripped"* ]] || [[ "$stripped" == "$candidate" ]]; then
                        service="$candidate"
                        break
                    fi
                done <<< "$all_services"
            fi

            # Use service name for display (fall back to stripped container name if still unknown)
            local short_name="${service:-${name#moav-}}"
            # Track by service name to avoid duplicates
            [[ -n "$service" ]] && displayed_services["$service"]=1

            # Format last run datetime
            last_run="-"
            if [[ -n "$created_at" ]]; then
                last_run=$(echo "$created_at" | cut -d' ' -f1,2)
            fi

            # For stopped containers, try to get finished time
            if [[ "$state" == "exited" ]]; then
                # Try to get FinishedAt from docker inspect
                finished_at=$(docker inspect --format '{{.State.FinishedAt}}' "$name" 2>/dev/null | cut -d'T' -f1,2 | tr 'T' ' ' | cut -d'.' -f1)
                if [[ -n "$finished_at" ]] && [[ "$finished_at" != "0001-01-01" ]]; then
                    last_run="$finished_at"
                fi
            fi

            # Parse uptime from Status field
            uptime="-"
            if [[ "$state" == "running" ]] && [[ "$status_str" =~ ^Up[[:space:]]+(.*) ]]; then
                uptime="${BASH_REMATCH[1]}"
                uptime="${uptime%% (*}"
                uptime="${uptime/About an /~1 }"
                uptime="${uptime/About a /~1 }"
                uptime="${uptime/Less than a /< 1 }"
            fi

            local status_display status_color
            if [[ "$state" == "running" ]]; then
                if [[ "$health" == "healthy" ]] || [[ -z "$health" ]]; then
                    status_color="${GREEN}"
                    status_display="● running"
                elif [[ "$health" == "unhealthy" ]]; then
                    status_color="${RED}"
                    status_display="○ unhealthy"
                else
                    status_color="${YELLOW}"
                    status_display="◐ starting"
                fi
            elif [[ "$state" == "exited" ]]; then
                status_color="${DIM}"
                status_display="○ exited "
                uptime="-"
            else
                status_color="${YELLOW}"
                status_display="◐ ${state}"
            fi

            [[ -z "$ports" ]] && ports="-"

            # Check if service is disabled and add indicator
            local display_name="$short_name"
            local name_color=""
            if [[ -n "${disabled_services[$short_name]:-}" ]]; then
                display_name="${short_name}*"
                name_color="${DIM}"
            fi

            # Note: %-14s for status to account for 3-byte Unicode symbols (●○◐) displaying as 1 char
            printf "  ${CYAN}│${NC} ${name_color}%-20s${NC} ${CYAN}│${NC} ${status_color}%-14s${NC} ${CYAN}│${NC} %-19s ${CYAN}│${NC} %-12s ${CYAN}│${NC} %-15s ${CYAN}│${NC}\n" \
                "$display_name" "$status_display" "$last_run" "$uptime" "$ports"
        done <<< "$json_lines"
    fi

    # Show services that have never been started (not in docker ps -a)
    while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        if [[ -z "${displayed_services[$service]:-}" ]]; then
            # Check if service is disabled
            local display_name="$service"
            local name_color="${DIM}"
            if [[ -n "${disabled_services[$service]:-}" ]]; then
                display_name="${service}*"
            fi

            printf "  ${CYAN}│${NC} ${name_color}%-20s${NC} ${CYAN}│${NC} ${DIM}%-12s${NC} ${CYAN}│${NC} %-19s ${CYAN}│${NC} %-12s ${CYAN}│${NC} %-15s ${CYAN}│${NC}\n" \
                "$display_name" "- never" "-" "-" "-"
        fi
    done <<< "$all_services"

    echo -e "  ${CYAN}└──────────────────────┴──────────────┴─────────────────────┴──────────────┴─────────────────┘${NC}"

    # Show legend if there are disabled services
    local has_disabled=false
    for key in "${!disabled_services[@]}"; do
        has_disabled=true
        break
    done
    if [[ "$has_disabled" == "true" ]]; then
        echo -e "  ${DIM}* = disabled in .env (won't start with 'moav start')${NC}"
    fi

    # Explain certbot status (often confusing to users)
    echo ""
    echo -e "  ${DIM}Note: certbot is a one-time service that obtains SSL certificates.${NC}"
    echo -e "  ${DIM}      Status 'Exited (0)' means it completed successfully.${NC}"
    echo ""
}

# Display service selection menu and populate SELECTED_PROFILES array
# Usage: select_profiles [mode]
#   mode: "save" to update .env, "start" for start menu, "stop" for stop menu
select_profiles() {
    local mode="${1:-}"
    SELECTED_PROFILES=()

    case "$mode" in
        start)   print_section "Start Services" ;;
        stop)    print_section "Stop Services" ;;
        restart) print_section "Restart Services" ;;
        *)       print_section "Select Services" ;;
    esac

    # Read ENABLE_* settings to show disabled status
    local env_file="$SCRIPT_DIR/.env"
    local proxy_enabled=true
    local wg_enabled=true
    local dnstunnel_enabled=true
    local amneziawg_enabled=true
    local trusttunnel_enabled=true
    local xhttp_enabled=false
    local telegram_enabled=true
    local admin_enabled=true

    if [[ -f "$env_file" ]]; then
        local enable_reality=$(get_env_val "ENABLE_REALITY" "$env_file" "true")
        local enable_trojan=$(get_env_val "ENABLE_TROJAN" "$env_file" "true")
        local enable_anytls=$(get_env_val "ENABLE_ANYTLS" "$env_file" "false")
        local enable_hysteria2=$(get_env_val "ENABLE_HYSTERIA2" "$env_file" "true")
        local enable_wireguard=$(get_env_val "ENABLE_WIREGUARD" "$env_file" "true")
        local enable_amneziawg=$(get_env_val "ENABLE_AMNEZIAWG" "$env_file" "true")
        local enable_dnstt=$(get_env_val "ENABLE_DNSTT" "$env_file" "true")
        local enable_slipstream=$(get_env_val "ENABLE_SLIPSTREAM" "$env_file" "true")
        local enable_trusttunnel=$(get_env_val "ENABLE_TRUSTTUNNEL" "$env_file" "true")
        local enable_telemt=$(get_env_val "ENABLE_TELEMT" "$env_file" "true")
        local enable_admin=$(get_env_val "ENABLE_ADMIN_UI" "$env_file" "true")
        local enable_xhttp=$(get_env_val "ENABLE_XHTTP" "$env_file" "true")

        # proxy is disabled if all sing-box protocols are disabled
        if [[ "$enable_reality" != "true" ]] && [[ "$enable_trojan" != "true" ]] && [[ "$enable_anytls" != "true" ]] && [[ "$enable_hysteria2" != "true" ]]; then
            proxy_enabled=false
        fi
        [[ "$enable_wireguard" != "true" ]] && wg_enabled=false
        [[ "$enable_amneziawg" != "true" ]] && amneziawg_enabled=false
        # dnstunnel is disabled if both dnstt and slipstream are disabled
        if [[ "$enable_dnstt" != "true" ]] && [[ "$enable_slipstream" != "true" ]]; then
            dnstunnel_enabled=false
        fi
        [[ "$enable_trusttunnel" != "true" ]] && trusttunnel_enabled=false
        [[ "$enable_xhttp" == "true" ]] && xhttp_enabled=true
        [[ "$enable_telemt" != "true" ]] && telegram_enabled=false
        [[ "$enable_admin" != "true" ]] && admin_enabled=false
    fi

    # Build menu lines with disabled indicators
    local proxy_line wg_line amneziawg_line dnstunnel_line trusttunnel_line xhttp_line telegram_line admin_line

    if [[ "$proxy_enabled" == "true" ]]; then
        proxy_line="  ${CYAN}│${NC}  ${GREEN}1${NC}   proxy        Reality, Trojan, Hysteria2 (v2ray apps)       ${CYAN}│${NC}"
    else
        proxy_line="  ${CYAN}│${NC}  ${DIM}1   proxy        Reality, Trojan, Hysteria2 (disabled)${NC}        ${CYAN}│${NC}"
    fi

    if [[ "$wg_enabled" == "true" ]]; then
        wg_line="  ${CYAN}│${NC}  ${GREEN}2${NC}   wireguard    WireGuard VPN + WebSocket tunnel              ${CYAN}│${NC}"
    else
        wg_line="  ${CYAN}│${NC}  ${DIM}2   wireguard    WireGuard VPN (disabled)${NC}                      ${CYAN}│${NC}"
    fi

    if [[ "$amneziawg_enabled" == "true" ]]; then
        amneziawg_line="  ${CYAN}│${NC}  ${GREEN}3${NC}   amneziawg    AmneziaWG (obfuscated WireGuard)               ${CYAN}│${NC}"
    else
        amneziawg_line="  ${CYAN}│${NC}  ${DIM}3   amneziawg    AmneziaWG (disabled)${NC}                         ${CYAN}│${NC}"
    fi

    if [[ "$dnstunnel_enabled" == "true" ]]; then
        dnstunnel_line="  ${CYAN}│${NC}  ${YELLOW}4${NC}   dnstunnel    DNS tunnels ${DIM}(dnstt + Slipstream)${NC}               ${CYAN}│${NC}"
    else
        dnstunnel_line="  ${CYAN}│${NC}  ${DIM}4   dnstunnel    DNS tunnels (disabled)${NC}                       ${CYAN}│${NC}"
    fi

    if [[ "$trusttunnel_enabled" == "true" ]]; then
        trusttunnel_line="  ${CYAN}│${NC}  ${GREEN}5${NC}   trusttunnel  TrustTunnel VPN (HTTP/2 + QUIC)               ${CYAN}│${NC}"
    else
        trusttunnel_line="  ${CYAN}│${NC}  ${DIM}5   trusttunnel  TrustTunnel VPN (disabled)${NC}                    ${CYAN}│${NC}"
    fi

    if [[ "$xhttp_enabled" == "true" ]]; then
        xhttp_line="  ${CYAN}│${NC}  ${GREEN}6${NC}   xhttp        VLESS+XHTTP+Reality (Xray-core)               ${CYAN}│${NC}"
    else
        xhttp_line="  ${CYAN}│${NC}  ${DIM}6   xhttp        VLESS+XHTTP+Reality (disabled)${NC}                ${CYAN}│${NC}"
    fi

    if [[ "$telegram_enabled" == "true" ]]; then
        telegram_line="  ${CYAN}│${NC}  ${GREEN}7${NC}   telegram     Telegram MTProxy (fake-TLS)                   ${CYAN}│${NC}"
    else
        telegram_line="  ${CYAN}│${NC}  ${DIM}7   telegram     Telegram MTProxy (disabled)${NC}                   ${CYAN}│${NC}"
    fi

    if [[ "$admin_enabled" == "true" ]]; then
        admin_line="  ${CYAN}│${NC}  ${GREEN}8${NC}   admin        Stats dashboard (port 9443)                   ${CYAN}│${NC}"
    else
        admin_line="  ${CYAN}│${NC}  ${DIM}8   admin        Stats dashboard (disabled)${NC}                   ${CYAN}│${NC}"
    fi

    echo ""
    echo -e "  ${CYAN}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${CYAN}│${NC}  ${WHITE}#${NC}   ${WHITE}Profile${NC}      ${WHITE}Description${NC}                                   ${CYAN}│${NC}"
    echo -e "  ${CYAN}├─────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "$proxy_line"
    echo -e "$wg_line"
    echo -e "$amneziawg_line"
    echo -e "$dnstunnel_line"
    echo -e "$trusttunnel_line"
    echo -e "$xhttp_line"
    echo -e "$telegram_line"
    echo -e "$admin_line"
    echo -e "  ${CYAN}├─────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${CYAN}│${NC}  ${BLUE}9${NC}   conduit      Donate bandwidth via Psiphon                  ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}  ${BLUE}10${NC}  snowflake    Donate bandwidth via Tor                      ${CYAN}│${NC}"
    echo -e "  ${CYAN}├─────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${CYAN}│${NC}  ${BLUE}11${NC}  monitoring   Grafana + Prometheus (requires 2GB RAM)       ${CYAN}│${NC}"
    echo -e "  ${CYAN}├─────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${CYAN}│${NC}  ${GREEN}a${NC}   ${GREEN}ALL${NC}          All services ${GREEN}(Recommended)${NC}                    ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}  ${DIM}0${NC}   ${DIM}Back${NC}         Back to main menu                             ${CYAN}│${NC}"
    echo -e "  ${CYAN}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""

    prompt "Enter choices (e.g., 1 2 4 or 1,2,4 or 'a' for all): "
    read -r choices < /dev/tty 2>/dev/null || choices=""

    if [[ "$choices" == "0" || -z "$choices" ]]; then
        return 2  # Return 2 to signal "go back" vs 1 for error
    fi

    # Support both space and comma separators
    choices="${choices//,/ }"

    if [[ "$choices" == "a" || "$choices" == "A" ]]; then
        # Build profile list based on ENABLE_* settings in .env
        # This way "all" means "all enabled services", not literally everything
        local env_file="$SCRIPT_DIR/.env"

        # Check which protocols are enabled
        local enable_reality=$(get_env_val "ENABLE_REALITY" "$env_file" "true")
        local enable_trojan=$(get_env_val "ENABLE_TROJAN" "$env_file" "true")
        local enable_anytls=$(get_env_val "ENABLE_ANYTLS" "$env_file" "false")
        local enable_hysteria2=$(get_env_val "ENABLE_HYSTERIA2" "$env_file" "true")
        local enable_wireguard=$(get_env_val "ENABLE_WIREGUARD" "$env_file" "true")
        local enable_amneziawg=$(get_env_val "ENABLE_AMNEZIAWG" "$env_file" "true")
        local enable_dnstt=$(get_env_val "ENABLE_DNSTT" "$env_file" "true")
        local enable_slipstream=$(get_env_val "ENABLE_SLIPSTREAM" "$env_file" "true")
        local enable_trusttunnel=$(get_env_val "ENABLE_TRUSTTUNNEL" "$env_file" "true")
        local enable_telemt=$(get_env_val "ENABLE_TELEMT" "$env_file" "true")
        local enable_admin=$(get_env_val "ENABLE_ADMIN_UI" "$env_file" "true")
        local enable_xhttp=$(get_env_val "ENABLE_XHTTP" "$env_file" "true")

        # Build profiles list based on enabled services
        SELECTED_PROFILES=()

        # proxy profile (Reality, Trojan, AnyTLS, Hysteria2)
        if [[ "$enable_reality" == "true" ]] || [[ "$enable_trojan" == "true" ]] || [[ "$enable_anytls" == "true" ]] || [[ "$enable_hysteria2" == "true" ]]; then
            SELECTED_PROFILES+=("proxy")
        fi

        # wireguard profile
        if [[ "$enable_wireguard" == "true" ]]; then
            SELECTED_PROFILES+=("wireguard")
        fi

        # amneziawg profile
        if [[ "$enable_amneziawg" == "true" ]]; then
            SELECTED_PROFILES+=("amneziawg")
        fi

        # dnstunnel profile (dnstt + Slipstream)
        if [[ "$enable_dnstt" == "true" ]] || [[ "$enable_slipstream" == "true" ]]; then
            SELECTED_PROFILES+=("dnstunnel")
        fi

        # trusttunnel profile
        if [[ "$enable_trusttunnel" == "true" ]]; then
            SELECTED_PROFILES+=("trusttunnel")
        fi

        # xhttp profile (Xray-core VLESS+XHTTP+Reality)
        if [[ "$enable_xhttp" == "true" ]]; then
            SELECTED_PROFILES+=("xhttp")
        fi

        # telegram profile (Telegram MTProxy)
        if [[ "$enable_telemt" == "true" ]]; then
            SELECTED_PROFILES+=("telegram")
        fi

        # admin profile
        if [[ "$enable_admin" == "true" ]]; then
            SELECTED_PROFILES+=("admin")
        fi

        # Donation services follow their ENABLE_* flags too (issue #106).
        # Pre-#106 these were appended unconditionally on the "all" path —
        # which started conduit/snowflake even when ENABLE_CONDUIT=false /
        # ENABLE_SNOWFLAKE=false was set in .env.
        local enable_conduit=$(get_env_val "ENABLE_CONDUIT" "$env_file" "true")
        local enable_snowflake=$(get_env_val "ENABLE_SNOWFLAKE" "$env_file" "true")
        local enable_gooserelay=$(get_env_val "ENABLE_GOOSERELAY" "$env_file" "false")
        [[ "$enable_conduit"    == "true" ]] && SELECTED_PROFILES+=("conduit")
        [[ "$enable_snowflake"  == "true" ]] && SELECTED_PROFILES+=("snowflake")
        [[ "$enable_gooserelay" == "true" ]] && SELECTED_PROFILES+=("gooserelay")

        # Check if monitoring should be included
        local enable_monitoring=$(get_env_val "ENABLE_MONITORING" "$env_file" "")
        if [[ "$enable_monitoring" == "true" ]]; then
            SELECTED_PROFILES+=("monitoring")
        elif [[ "$enable_monitoring" != "false" ]]; then
            # Not explicitly set - ask user
            echo ""
            warn "Monitoring stack (Grafana + Prometheus) requires at least 2GB RAM."
            if confirm "Enable monitoring?" "$(monitoring_default_for_ram)"; then
                update_env_var "$env_file" "ENABLE_MONITORING" "true"
                SELECTED_PROFILES+=("monitoring")
                success "Monitoring enabled"
            else
                # Explicitly disable to avoid asking again
                update_env_var "$env_file" "ENABLE_MONITORING" "false"
                info "Monitoring skipped. Enable later with: moav start monitoring"
            fi
        fi
        # If explicitly false, don't include monitoring

        # If nothing enabled, error out — auto-forcing donation services
        # on (pre-#106 behavior: SELECTED_PROFILES=("conduit" "snowflake")) is
        # exactly the bug the issue describes. The operator should pick
        # something or flip an ENABLE_* flag.
        if [[ ${#SELECTED_PROFILES[@]} -eq 0 ]]; then
            warn "No services are enabled in .env (every ENABLE_* is false)."
            echo "  Set at least one ENABLE_*=true in .env, or pick a specific profile."
            return 1
        fi

        # Show what "all enabled" actually means
        echo ""
        info "Selected profiles based on your configuration: ${SELECTED_PROFILES[*]}"
    else
        for choice in $choices; do
            case $choice in
                1) SELECTED_PROFILES+=("proxy") ;;
                2) SELECTED_PROFILES+=("wireguard") ;;
                3) SELECTED_PROFILES+=("amneziawg") ;;
                4) SELECTED_PROFILES+=("dnstunnel") ;;
                5) SELECTED_PROFILES+=("trusttunnel") ;;
                6) SELECTED_PROFILES+=("xhttp") ;;
                7) SELECTED_PROFILES+=("telegram") ;;
                8) SELECTED_PROFILES+=("admin") ;;
                9) SELECTED_PROFILES+=("conduit") ;;
                10) SELECTED_PROFILES+=("snowflake") ;;
                11) SELECTED_PROFILES+=("monitoring") ;;
            esac
        done
    fi

    # DNS tunnels require sing-box (proxy profile) to forward traffic
    # Auto-add proxy if dnstunnel is selected but proxy isn't (only for start operations)
    if [[ "$mode" != "stop" ]] && [[ "$mode" != "restart" ]]; then
        local has_dnstunnel=false has_proxy=false
        for p in "${SELECTED_PROFILES[@]}"; do
            [[ "$p" == "dnstunnel" ]] && has_dnstunnel=true
            [[ "$p" == "proxy" ]] && has_proxy=true
        done
        if [[ "$has_dnstunnel" == "true" ]] && [[ "$has_proxy" == "false" ]]; then
            info "DNS tunnels require proxy services - auto-adding proxy profile"
            SELECTED_PROFILES+=("proxy")
        fi
    fi

    if [[ ${#SELECTED_PROFILES[@]} -eq 0 ]]; then
        warn "No profiles selected"
        return 1
    fi

    # Build profile string for docker compose
    SELECTED_PROFILE_STRING=""
    for p in "${SELECTED_PROFILES[@]}"; do
        SELECTED_PROFILE_STRING+="--profile $p "
    done

    # Save to .env if requested
    if [[ "$mode" == "save" ]]; then
        save_default_profiles
    fi

    return 0
}

# Save selected profiles to .env
save_default_profiles() {
    local profiles_str="${SELECTED_PROFILES[*]}"
    local env_file="$SCRIPT_DIR/.env"

    if [[ ! -f "$env_file" ]]; then
        warn "No .env file found, cannot save defaults"
        return 1
    fi

    # Update or add DEFAULT_PROFILES in .env (with quotes to handle spaces)
    if grep -q "^DEFAULT_PROFILES=" "$env_file" 2>/dev/null; then
        # Update existing line
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s/^DEFAULT_PROFILES=.*/DEFAULT_PROFILES=\"$profiles_str\"/" "$env_file"
        else
            sed -i "s/^DEFAULT_PROFILES=.*/DEFAULT_PROFILES=\"$profiles_str\"/" "$env_file"
        fi
    else
        # Add new line
        echo "" >> "$env_file"
        echo "# Default profiles for 'moav start'" >> "$env_file"
        echo "DEFAULT_PROFILES=\"$profiles_str\"" >> "$env_file"
    fi

    success "Saved default profiles: $profiles_str"
}

# Get default profiles from .env
get_default_profiles() {
    local env_file="$SCRIPT_DIR/.env"
    if [[ -f "$env_file" ]]; then
        grep "^DEFAULT_PROFILES=" "$env_file" 2>/dev/null | cut -d'=' -f2 | sed 's/#.*//' | tr -d '"' | tr -d "'" | xargs
    fi
}

# Profile ↔ ENABLE_* mapping (issue #106) — Compose profiles don't know
# about MoaV's ENABLE_* flags. These helpers are the bridge.

# Is <profile> enabled in .env? Multi-flag profiles survive if any flag is on.
profile_enabled() {
    local profile="$1" env_file="${2:-$SCRIPT_DIR/.env}"
    case "$profile" in
        proxy)
            local _r _t _a _h _s
            _r=$(get_env_val "ENABLE_REALITY"   "$env_file" "true")
            _t=$(get_env_val "ENABLE_TROJAN"    "$env_file" "true")
            _a=$(get_env_val "ENABLE_ANYTLS"    "$env_file" "false")
            _h=$(get_env_val "ENABLE_HYSTERIA2" "$env_file" "true")
            _s=$(get_env_val "ENABLE_SS"        "$env_file" "true")
            [[ "$_r" == "true" || "$_t" == "true" || "$_a" == "true" || "$_h" == "true" || "$_s" == "true" ]] \
                && echo true || echo false ;;
        wireguard)   [[ "$(get_env_val "ENABLE_WIREGUARD"   "$env_file" "true")"  == "true" ]] && echo true || echo false ;;
        amneziawg)   [[ "$(get_env_val "ENABLE_AMNEZIAWG"   "$env_file" "true")"  == "true" ]] && echo true || echo false ;;
        dnstunnel)
            local _d _s _m _x
            _d=$(get_env_val "ENABLE_DNSTT"     "$env_file" "true")
            _s=$(get_env_val "ENABLE_SLIPSTREAM" "$env_file" "true")
            _m=$(get_env_val "ENABLE_MASTERDNS" "$env_file" "true")
            _x=$(get_env_val "ENABLE_XDNS"      "$env_file" "true")
            [[ "$_d" == "true" || "$_s" == "true" || "$_m" == "true" || "$_x" == "true" ]] \
                && echo true || echo false ;;
        trusttunnel) [[ "$(get_env_val "ENABLE_TRUSTTUNNEL" "$env_file" "true")"  == "true" ]] && echo true || echo false ;;
        xhttp)       [[ "$(get_env_val "ENABLE_XHTTP"       "$env_file" "true")"  == "true" ]] && echo true || echo false ;;
        telegram)    [[ "$(get_env_val "ENABLE_TELEMT"      "$env_file" "true")"  == "true" ]] && echo true || echo false ;;
        admin)       [[ "$(get_env_val "ENABLE_ADMIN_UI"    "$env_file" "true")"  == "true" ]] && echo true || echo false ;;
        conduit)     [[ "$(get_env_val "ENABLE_CONDUIT"     "$env_file" "true")"  == "true" ]] && echo true || echo false ;;
        snowflake)   [[ "$(get_env_val "ENABLE_SNOWFLAKE"   "$env_file" "true")"  == "true" ]] && echo true || echo false ;;
        gooserelay)  [[ "$(get_env_val "ENABLE_GOOSERELAY"  "$env_file" "false")" == "true" ]] && echo true || echo false ;;
        monitoring)
            # Opt-in via interactive prompt; explicit false drops, anything else passes.
            local _m=$(get_env_val "ENABLE_MONITORING" "$env_file" "")
            [[ "$_m" == "false" ]] && echo false || echo true ;;
        *) echo true ;;   # setup, client, all, unknown — pass through.
    esac
}

# Canonical space-separated list to write into DEFAULT_PROFILES.
derive_enabled_profiles() {
    local env_file="${1:-$SCRIPT_DIR/.env}"
    local out=()
    local p
    for p in proxy xhttp wireguard amneziawg dnstunnel trusttunnel telegram admin conduit snowflake gooserelay; do
        [[ "$(profile_enabled "$p" "$env_file")" == "true" ]] && out+=("$p")
    done
    echo "${out[*]}"
}

# Drop disabled profiles from $1; print one info line if anything dropped.
filter_disabled_profiles() {
    local profiles="$1" env_file="${2:-$SCRIPT_DIR/.env}"
    local kept=() dropped=()
    local p
    for p in $profiles; do
        if [[ "$(profile_enabled "$p" "$env_file")" == "true" ]]; then
            kept+=("$p")
        else
            dropped+=("$p")
        fi
    done
    if [[ ${#dropped[@]} -gt 0 ]]; then
        info "Skipping disabled profiles (set ENABLE_*=true in .env to enable): ${dropped[*]}" >&2
    fi
    echo "${kept[*]}"
}

# 3-option prompt for explicit `moav start <name>` when ENABLE_* is false.
# Echoes: start-and-enable | skip | start-once
confirm_disabled_profile() {
    local profile="$1" env_file="${2:-$SCRIPT_DIR/.env}"
    # Single-flag profiles can be auto-flipped; multi-flag (proxy/dnstunnel)
    # need the operator to pick which sub-flag to enable.
    local enable_var="" multi_flag_hint=""
    case "$profile" in
        wireguard)   enable_var="ENABLE_WIREGUARD" ;;
        amneziawg)   enable_var="ENABLE_AMNEZIAWG" ;;
        trusttunnel) enable_var="ENABLE_TRUSTTUNNEL" ;;
        xhttp)       enable_var="ENABLE_XHTTP" ;;
        telegram)    enable_var="ENABLE_TELEMT" ;;
        admin)       enable_var="ENABLE_ADMIN_UI" ;;
        conduit)     enable_var="ENABLE_CONDUIT" ;;
        snowflake)   enable_var="ENABLE_SNOWFLAKE" ;;
        gooserelay)  enable_var="ENABLE_GOOSERELAY" ;;
        monitoring)  enable_var="ENABLE_MONITORING" ;;
        proxy)       multi_flag_hint="ENABLE_REALITY, ENABLE_TROJAN, ENABLE_ANYTLS, ENABLE_HYSTERIA2, ENABLE_SS" ;;
        dnstunnel)   multi_flag_hint="ENABLE_DNSTT, ENABLE_SLIPSTREAM, ENABLE_MASTERDNS, ENABLE_XDNS" ;;
    esac

    echo "" >&2
    warn "Profile '$profile' is disabled in .env." >&2
    echo "" >&2
    echo -e "  ${WHITE}What would you like to do?${NC}" >&2
    if [[ -n "$enable_var" ]]; then
        echo "    1) Enable + start  — set ${enable_var}=true in .env and start now (persists)" >&2
    else
        echo "    1) Enable manually — '$profile' covers $multi_flag_hint;" >&2
        echo "                          set one to true in .env, then re-run" >&2
    fi
    echo "    2) Skip            — don't start; leave .env unchanged" >&2
    echo "    3) Start once      — start now without touching .env (won't auto-start next time)" >&2
    echo "" >&2

    local choice=""
    if [[ ! -t 0 ]]; then
        info "Non-interactive shell, skipping '$profile'." >&2
        echo "skip"
        return 0
    fi
    read -p "  Choice [1/2/3] (default 2): " choice >&2
    case "$choice" in
        1)
            if [[ -z "$enable_var" ]]; then
                # Multi-flag — can't auto-flip. Direct the operator and skip
                # (don't silently fall through to start-once; they explicitly
                # asked for the persistent path).
                warn "Skipping — flip one of [$multi_flag_hint] in .env, then re-run." >&2
                echo "skip"
                return 0
            fi
            update_env_var "$env_file" "$enable_var" "true"
            success "Set ${enable_var}=true in .env" >&2
            echo "start-and-enable"
            ;;
        3)
            echo "start-once"
            ;;
        *)
            echo "skip"
            ;;
    esac
}

# Ensure CLASH_API_SECRET is set in .env for monitoring
# This is needed for clash-exporter to authenticate with sing-box Clash API
# Returns: 0 = continue, 1 = skip monitoring (user declined when using 'all' profile)
# Materialize the Conduit lifetime recording-rules file before Prometheus
# bind-mounts it. The live file is gitignored and runtime-rewritten by
# update-conduit-offsets.sh (it bakes in the per-install OFFSET values), so the
# repo ships a committed `.template` (offsets at 0) and we copy it into place on
# first monitoring start. Never clobber an existing file — it holds the
# operator's banked offsets.
ensure_conduit_lifetime_rules() {
    local rules="$SCRIPT_DIR/configs/monitoring/conduit_lifetime.rules.yml"
    local template="${rules}.template"
    if [[ ! -f "$rules" && -f "$template" ]]; then
        cp "$template" "$rules"
    fi
}

ensure_clash_api_secret() {
    local profiles="$1"
    local env_file="$SCRIPT_DIR/.env"

    # Only needed if monitoring or all profile is being started
    if ! echo "$profiles" | grep -qE "monitoring|all"; then
        return 0
    fi

    # Make sure Prometheus has its Conduit rules file to mount (gitignored +
    # runtime-generated, so it may be absent on a fresh checkout).
    ensure_conduit_lifetime_rules

    # Check if ENABLE_MONITORING is explicitly set to false
    local enable_monitoring
    enable_monitoring=$(get_env_val "ENABLE_MONITORING" "$env_file" "")
    if [[ "$enable_monitoring" == "false" ]]; then
        echo ""
        warn "Monitoring is currently disabled in .env (ENABLE_MONITORING=false)"
        if confirm "Enable monitoring?" "$(monitoring_default_for_ram)"; then
            update_env_var "$env_file" "ENABLE_MONITORING" "true"
            success "ENABLE_MONITORING set to true"
        else
            info "Skipping monitoring. Starting other services..."
            return 1  # Signal caller to skip monitoring
        fi
    fi

    # Check if CLASH_API_SECRET is already set in .env (non-empty)
    # Note: || true needed because set -o pipefail causes exit if grep finds nothing
    local current_secret
    current_secret=$(grep "^CLASH_API_SECRET=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" || true)

    # Get the authoritative secret from state volume (source of truth from bootstrap)
    local state_secret
    state_secret=$(docker run --rm -v moav_moav_state:/state alpine cat /state/keys/clash-api.env 2>/dev/null | grep "^CLASH_API_SECRET=" | cut -d'=' -f2 || true)

    # If .env matches state, we're good
    if [[ -n "$current_secret" ]] && [[ "$current_secret" == "$state_secret" ]]; then
        return 0  # Already configured and in sync
    fi

    # If .env has a value but it doesn't match state, it's stale
    if [[ -n "$current_secret" ]] && [[ -n "$state_secret" ]] && [[ "$current_secret" != "$state_secret" ]]; then
        warn "CLASH_API_SECRET in .env doesn't match state volume (stale after re-bootstrap)"
        info "Syncing CLASH_API_SECRET from state volume..."
        sed -i.bak "s/^CLASH_API_SECRET=.*/CLASH_API_SECRET=$state_secret/" "$env_file"
        rm -f "$env_file.bak"
        success "CLASH_API_SECRET synced"
        return 0
    fi

    # .env is empty — first-time monitoring setup
    # If using 'all' profile, ask user if they want to enable monitoring (requires 2GB RAM)
    # Skip if user already confirmed monitoring above (ENABLE_MONITORING was false -> set to true)
    if [[ -z "$current_secret" ]] && [[ "$enable_monitoring" != "false" ]]; then
        if echo "$profiles" | grep -qE "\ball\b|--profile all"; then
            echo ""
            warn "Monitoring requires at least 2GB RAM to run properly."
            echo "  The monitoring stack includes Grafana, Prometheus, and exporters."
            echo ""
            if ! confirm "Enable monitoring? (You can start it later with 'moav start monitoring')" "n"; then
                info "Skipping monitoring. Starting other services..."
                return 1  # Signal caller to skip monitoring
            fi
        fi
    fi

    # Try to use state secret, fall back to sing-box config
    local secret="$state_secret"
    if [[ -z "$secret" ]]; then
        # Try to extract from existing sing-box config.json
        if [[ -f "$SCRIPT_DIR/configs/sing-box/config.json" ]]; then
            secret=$(grep -o '"secret"[[:space:]]*:[[:space:]]*"[^"]*"' "$SCRIPT_DIR/configs/sing-box/config.json" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)
        fi
    fi

    if [[ -n "$secret" ]]; then
        info "Configuring CLASH_API_SECRET for monitoring..."
        # Update .env file
        if grep -q "^CLASH_API_SECRET=" "$env_file" 2>/dev/null; then
            sed -i.bak "s/^CLASH_API_SECRET=.*/CLASH_API_SECRET=$secret/" "$env_file"
            rm -f "$env_file.bak"
        else
            # Append to file
            echo "" >> "$env_file"
            echo "# Clash API secret for monitoring (auto-configured)" >> "$env_file"
            echo "CLASH_API_SECRET=$secret" >> "$env_file"
        fi
        success "CLASH_API_SECRET configured"
    else
        warn "Could not find CLASH_API_SECRET. Clash exporter may not authenticate properly."
        echo "  If sing-box metrics show empty, run: moav bootstrap"
    fi
    return 0
}

start_services() {
    # Use the unified service selection menu
    SELECTED_PROFILE_STRING=""
    local ret=0
    select_profiles "start" || ret=$?
    [[ $ret -eq 2 ]] && return 2  # User chose "Back"
    [[ $ret -ne 0 ]] && return 1

    local profiles="$SELECTED_PROFILE_STRING"
    if [[ -z "$profiles" ]]; then
        warn "No profiles selected"
        return 1
    fi

    # Check if bootstrap has been run
    if ! check_bootstrap; then
        warn "Bootstrap has not been run yet!"
        echo ""
        info "Bootstrap is required for first-time setup."
        echo ""

        if confirm "Run bootstrap now?" "y"; then
            run_bootstrap || return 1
            echo ""
        else
            warn "Cannot start services without bootstrap."
            return 1
        fi
    fi

    # Ensure CLASH_API_SECRET is configured for monitoring
    # Returns 1 if user declined monitoring when using 'all' profile
    local skip_monitoring=0
    ensure_clash_api_secret "$profiles" || skip_monitoring=1
    if [[ $skip_monitoring -eq 1 ]]; then
        # User declined monitoring — replace 'all' with derived enabled set (issue #106).
        local _enabled
        _enabled=$(derive_enabled_profiles "$SCRIPT_DIR/.env")
        profiles=""
        local _p
        for _p in $_enabled; do
            profiles+="--profile $_p "
        done
    fi

    echo ""
    info "Building containers (if needed)..."

    local cmd="docker compose $profiles up -d --remove-orphans"

    if run_command "$cmd" "Starting services"; then
        echo ""
        success "Services started!"
        echo ""
        # Show admin URL if admin was started
        if echo "$profiles" | grep -qE "admin|all"; then
            echo -e "  ${CYAN}Admin Dashboard:${NC} $(get_admin_url)"
        fi
        # Show Grafana URL if monitoring was started
        if echo "$profiles" | grep -qE "monitoring|all"; then
            echo -e "  ${CYAN}Grafana:${NC}         $(get_grafana_url)"
            local grafana_cdn=$(get_grafana_cdn_url)
            if [[ -n "$grafana_cdn" ]]; then
                echo -e "  ${CYAN}Grafana (CDN):${NC}   $grafana_cdn"
            fi
        fi

        if echo "$profiles" | grep -qE "admin|monitoring|all"; then
            echo ""
        fi
        show_log_help
    fi
}

stop_services() {
    # Check if any services are running
    local running_services
    running_services=$(docker compose ps --services --filter "status=running" 2>/dev/null | sort)

    if [[ -z "$running_services" ]]; then
        print_section "Stop Services"
        warn "No services are currently running"
        return 0
    fi

    # Use the unified service selection menu
    SELECTED_PROFILE_STRING=""
    local ret=0
    select_profiles "stop" || ret=$?
    [[ $ret -eq 2 ]] && return 2  # User chose "Back"
    [[ $ret -ne 0 ]] && return 1

    local profiles="$SELECTED_PROFILE_STRING"
    if [[ -z "$profiles" ]]; then
        warn "No profiles selected"
        return 1
    fi

    echo ""
    info "Stopping services..."

    if [[ "$profiles" == "--profile all" ]]; then
        docker compose --profile all stop
    else
        # Stop each selected profile
        docker compose $profiles stop
    fi

    success "Services stopped!"
}

restart_services() {
    # Check if any services are running
    local running_services
    running_services=$(docker compose ps --services --filter "status=running" 2>/dev/null | sort)

    if [[ -z "$running_services" ]]; then
        print_section "Restart Services"
        warn "No services are currently running"
        return 0
    fi

    # Use the unified service selection menu
    SELECTED_PROFILE_STRING=""
    local ret=0
    select_profiles "restart" || ret=$?
    [[ $ret -eq 2 ]] && return 2  # User chose "Back"
    [[ $ret -ne 0 ]] && return 1

    local profiles="$SELECTED_PROFILE_STRING"
    if [[ -z "$profiles" ]]; then
        warn "No profiles selected"
        return 1
    fi

    echo ""
    info "Restarting services..."

    if [[ "$profiles" == "--profile all" ]]; then
        docker compose --profile all restart
    else
        docker compose $profiles restart
    fi

    success "Services restarted!"
}

# Format Docker timestamps from ISO to readable format
# 2026-02-04T20:17:10.426340440Z -> 2026-02-04 20:17:10
format_log_timestamps() {
    sed -u 's/\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)T\([0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\)\.[0-9]*Z/\1 \2/g'
}

view_logs() {
    local log_interrupted=false

    while true; do
        log_interrupted=false
        print_section "View Logs"

        # Get all services (running or not)
        local all_services
        all_services=$(docker compose ps --services -a 2>/dev/null | sort)

        echo "Options:"
        echo ""
        echo -e "  ${WHITE}a)${NC} All services (follow)"
        echo -e "  ${WHITE}t)${NC} Last 100 lines + follow (all services)"

        if [[ -n "$all_services" ]]; then
            echo ""
            local i=1
            local services_array=()
            while IFS= read -r svc; do
                [[ -z "$svc" ]] && continue
                services_array+=("$svc")
                echo -e "  ${WHITE}$i)${NC} $svc"
                ((i++))
            done <<< "$all_services"
        fi

        echo ""
        echo -e "  ${WHITE}0)${NC} Back to main menu"
        echo ""

        prompt "Choice: "
        read -r choice < /dev/tty 2>/dev/null || choice=""

        case $choice in
            a|A)
                echo ""
                info "Showing logs for all services. Press Ctrl+C to return to menu."
                echo ""
                # Trap SIGINT to return to menu instead of exiting
                trap 'log_interrupted=true' INT
                docker compose --ansi always --profile all logs -t -f 2>/dev/null | format_log_timestamps || true
                trap - INT
                [[ "$log_interrupted" == "true" ]] && echo "" && info "Returning to log menu..."
                ;;
            t|T)
                echo ""
                info "Showing last 100 lines + follow. Press Ctrl+C to return to menu."
                echo ""
                trap 'log_interrupted=true' INT
                docker compose --ansi always --profile all logs -t --tail=100 -f 2>/dev/null | format_log_timestamps || true
                trap - INT
                [[ "$log_interrupted" == "true" ]] && echo "" && info "Returning to log menu..."
                ;;
            0|"")
                return 0
                ;;
            [1-9]*)
                local idx=$((choice - 1))
                if [[ $idx -ge 0 && $idx -lt ${#services_array[@]} ]]; then
                    local service="${services_array[$idx]}"
                    echo ""
                    info "Showing logs for $service. Press Ctrl+C to return to menu."
                    echo ""
                    # Trap SIGINT to return to menu instead of exiting
                    trap 'log_interrupted=true' INT
                    docker compose --ansi always logs -t -f "$service" 2>/dev/null | format_log_timestamps || true
                    trap - INT
                    [[ "$log_interrupted" == "true" ]] && echo "" && info "Returning to log menu..."
                else
                    warn "Invalid choice"
                fi
                ;;
            *)
                warn "Invalid choice"
                ;;
        esac
    done
}

show_log_help() {
    echo -e "${CYAN}Log Commands:${NC}"
    echo "  • View all logs:      docker compose logs -t -f"
    echo "  • View service logs:  docker compose logs -t -f sing-box"
    echo "  • Last 100 lines:     docker compose logs -t --tail=100"
    echo ""
    echo -e "${CYAN}Useful Commands:${NC}"
    echo "  • Check status:       docker compose ps"
    echo "  • Stop all:           docker compose --profile all stop"
    echo "  • Restart service:    docker compose restart sing-box"
}

# =============================================================================
# User Management
# =============================================================================

user_management() {
    while true; do
        print_section "User Management"

        echo "User management options:"
        echo ""
        echo -e "  ${WHITE}1)${NC} List all users"
        echo -e "  ${WHITE}2)${NC} Add new user"
        echo -e "  ${WHITE}3)${NC} Revoke user"
        echo -e "  ${WHITE}4)${NC} Package user (create zip)"
        echo -e "  ${WHITE}0)${NC} Back to main menu"
        echo ""

        prompt "Choice: "
        read -r choice < /dev/tty 2>/dev/null || choice=""

        case $choice in
            1)
                list_users
                ;;
            2)
                add_user
                press_enter
                ;;
            3)
                revoke_user
                press_enter
                ;;
            4)
                package_user
                press_enter
                ;;
            0|q|Q)
                return 0
                ;;
            *)
                ;;
        esac
    done
}

migration_menu() {
    print_section "Export/Import (Migration)"

    echo "Migration options:"
    echo ""
    echo -e "  ${WHITE}1)${NC} Export configuration backup"
    echo -e "  ${WHITE}2)${NC} Import configuration backup"
    echo -e "  ${WHITE}3)${NC} Migrate to new IP address"
    echo -e "  ${WHITE}4)${NC} Regenerate all user bundles"
    echo -e "  ${WHITE}0)${NC} Back to main menu"
    echo ""

    prompt "Choice: "
    read -r choice < /dev/tty 2>/dev/null || choice=""

    case $choice in
        1)
            echo ""
            local default_file="moav-backup-$(date +%Y%m%d_%H%M%S).tar.gz"
            prompt "Output file [$default_file]: "
            read -r output_file < /dev/tty 2>/dev/null || output_file=""
            [[ -z "$output_file" ]] && output_file="$default_file"
            cmd_export "$output_file"
            ;;
        2)
            echo ""
            prompt "Backup file to import: "
            read -r input_file < /dev/tty 2>/dev/null || input_file=""
            if [[ -n "$input_file" ]]; then
                cmd_import "$input_file"
            else
                warn "No file specified"
            fi
            ;;
        3)
            echo ""
            local current_ip=$(grep -E '^SERVER_IP=' .env 2>/dev/null | cut -d= -f2 | tr -d '"')
            local current_ipv6=$(grep -E '^SERVER_IPV6=' .env 2>/dev/null | cut -d= -f2 | tr -d '"')
            local detected_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
            local detected_ipv6=$(curl -6 -s --max-time 3 https://api6.ipify.org 2>/dev/null || echo "")
            [[ -n "$current_ip" ]] && echo "Current IP in .env: $current_ip"
            [[ -n "$current_ipv6" ]] && echo "Current IPv6 in .env: $current_ipv6"
            [[ -n "$detected_ip" ]] && echo "Detected server IP: $detected_ip"
            [[ -n "$detected_ipv6" ]] && echo "Detected server IPv6: $detected_ipv6"
            echo ""
            prompt "New IP address: "
            read -r new_ip < /dev/tty 2>/dev/null || new_ip=""
            if [[ -n "$new_ip" ]]; then
                cmd_migrate_ip "$new_ip"
            else
                warn "No IP specified"
            fi
            ;;
        4)
            cmd_regenerate_users
            ;;
        0|*)
            return 0
            ;;
    esac
}

list_users() {
    print_section "User List"

    if [[ -x "./scripts/user-list.sh" ]]; then
        ./scripts/user-list.sh
    else
        # Fallback: list from outputs/bundles
        if [[ -d "outputs/bundles" ]]; then
            echo "Users with bundles:"
            ls -1 outputs/bundles/ 2>/dev/null || echo "  No users found"
        else
            warn "No users found. Run bootstrap first."
        fi
    fi
}

add_user() {
    print_section "Add New User"

    prompt "Enter username for new user: "
    read -r username < /dev/tty 2>/dev/null || username=""

    if [[ -z "$username" ]]; then
        warn "Username cannot be empty"
        return 1
    fi

    # Validate username (alphanumeric and underscore only)
    if [[ ! "$username" =~ ^[a-zA-Z0-9_]+$ ]]; then
        error "Username can only contain letters, numbers, and underscores"
        return 1
    fi

    echo ""
    echo "This will add '$username' to all enabled services:"
    echo "  • Proxies — Reality, Trojan, Hysteria2, Shadowsocks-2022, XHTTP, CDN VLESS+WS"
    echo "  • VPN — WireGuard (direct + wstunnel), AmneziaWG, TrustTunnel"
    echo "  • DNS tunnels — dnstt, Slipstream, MasterDNS, XDNS"
    echo "  • Telegram MTProxy"
    echo "  • GooseRelay (if ENABLE_GOOSERELAY=true)"
    echo ""
    echo "  Bundle: outputs/bundles/$username/  (~40 files: configs, QR codes,"
    echo "  V2Ray subscription, README.html)"
    echo ""

    if [[ -x "./scripts/user-add.sh" ]]; then
        run_command "./scripts/user-add.sh $username" "Adding user $username"

        if [[ $? -eq 0 ]]; then
            echo ""
            success "User '$username' created!"
            echo ""
            info "Bundle location: outputs/bundles/$username/"
            echo "  Share this bundle securely with the user."
        fi
    else
        error "User add script not found: ./scripts/user-add.sh"
        return 1
    fi
}

revoke_user() {
    print_section "Revoke User"

    echo "Current users:"
    list_users
    echo ""

    prompt "Enter username to revoke: "
    read -r username < /dev/tty 2>/dev/null || username=""

    if [[ -z "$username" ]]; then
        warn "Username cannot be empty"
        return 1
    fi

    echo ""
    warn "This will revoke '$username' from ALL services!"
    echo ""

    if [[ -x "./scripts/user-revoke.sh" ]]; then
        if confirm "Are you sure you want to revoke '$username'?"; then
            run_command "./scripts/user-revoke.sh $username" "Revoking user $username"

            if [[ $? -eq 0 ]]; then
                echo ""
                success "User '$username' revoked!"
            fi
        fi
    else
        error "User revoke script not found: ./scripts/user-revoke.sh"
        return 1
    fi
}

package_user() {
    print_section "Package User"

    echo "Current users:"
    list_users
    echo ""

    prompt "Enter username to package: "
    read -r username < /dev/tty 2>/dev/null || username=""

    if [[ -z "$username" ]]; then
        warn "Username cannot be empty"
        return 1
    fi

    local bundle_dir="outputs/bundles/$username"
    if [[ ! -d "$bundle_dir" ]]; then
        error "User bundle not found: $bundle_dir"
        return 1
    fi

    local zip_file="outputs/bundles/${username}-configs.zip"

    # Check for zip command
    if ! command -v zip &>/dev/null; then
        error "zip command not found. Install with: apt install zip"
        return 1
    fi

    info "Creating package for $username..."

    # Create zip from bundle directory
    (cd outputs/bundles && zip -r "${username}-configs.zip" "$username" -x "*.DS_Store")

    if [[ -f "$zip_file" ]]; then
        local size=$(du -h "$zip_file" | cut -f1)
        success "Package created: $zip_file ($size)"
    else
        error "Failed to create package"
        return 1
    fi
}

# =============================================================================
# Build Management
# =============================================================================

build_services() {
    print_section "Build Services"

    # Get all available services from compose
    local all_services
    all_services=$(docker compose --profile all config --services 2>/dev/null | sort)

    echo "Build options:"
    echo ""
    echo -e "  ${WHITE}a)${NC} Build all services"
    echo -e "  ${WHITE}n)${NC} Build all (no cache)"

    if [[ -n "$all_services" ]]; then
        echo ""
        echo "Build specific service:"
        local i=1
        local services_array=()
        while IFS= read -r svc; do
            [[ -z "$svc" ]] && continue
            services_array+=("$svc")
            echo -e "  ${WHITE}$i)${NC} $svc"
            ((i++))
        done <<< "$all_services"
    fi

    echo ""
    echo -e "  ${WHITE}0)${NC} Cancel"
    echo ""

    prompt "Choice: "
    read -r choice < /dev/tty 2>/dev/null || choice=""

    case $choice in
        a|A)
            echo ""
            info "Building all services..."
            compose_build --profile all build
            success "Build complete!"
            ;;
        n|N)
            echo ""
            info "Building all services (no cache)..."
            compose_build --profile all build --no-cache
            success "Build complete!"
            ;;
        0|"")
            return 0
            ;;
        [1-9]*)
            local idx=$((choice - 1))
            if [[ $idx -ge 0 && $idx -lt ${#services_array[@]} ]]; then
                local service="${services_array[$idx]}"
                echo ""
                info "Building $service..."
                compose_build build "$service"
                success "$service built!"
            else
                warn "Invalid choice"
            fi
            ;;
        *)
            warn "Invalid choice"
            ;;
    esac
}

# =============================================================================
# Main Menu
# =============================================================================

main_menu() {
    while true; do
        print_header

        # Show quick status
        local running=$(get_running_services)
        if [[ -n "$running" ]]; then
            echo -e "  ${GREEN}●${NC} Services running: $(echo $running | wc -w)"
            # Show admin URL if admin is running
            if echo "$running" | grep -q "admin"; then
                echo -e "  ${CYAN}↳${NC} Admin: ${CYAN}$(get_admin_url)${NC}"
            fi
            # Show Grafana URL if grafana is running
            if echo "$running" | grep -q "grafana"; then
                echo -e "  ${CYAN}↳${NC} Grafana: ${CYAN}$(get_grafana_url)${NC}"
            fi
        else
            echo -e "  ${DIM}○ No services running${NC}"
        fi
        echo ""

        echo "  What would you like to do?"
        echo ""
        echo -e "  ${DIM}Services${NC}"
        echo -e "  ${WHITE}1)${NC} Start services"
        echo -e "  ${WHITE}2)${NC} Stop services"
        echo -e "  ${WHITE}3)${NC} Restart services"
        echo -e "  ${WHITE}4)${NC} View status"
        echo -e "  ${WHITE}5)${NC} View logs"
        echo ""
        echo -e "  ${DIM}Users & donations${NC}"
        echo -e "  ${WHITE}6)${NC} User management"
        echo -e "  ${WHITE}7)${NC} Donate configs (MahsaNet, Psiphon, Snowflake)"
        echo ""
        echo -e "  ${DIM}System${NC}"
        echo -e "  ${WHITE}8)${NC}  Doctor — diagnose problems"
        echo -e "  ${WHITE}9)${NC}  Admin password reset"
        echo -e "  ${WHITE}10)${NC} Update MoaV"
        echo -e "  ${WHITE}11)${NC} Build/rebuild services"
        echo -e "  ${WHITE}12)${NC} Export/Import (migration)"
        echo ""
        echo -e "  ${WHITE}0)${NC}  Exit"
        echo ""

        prompt "Choice: "
        read -r choice < /dev/tty 2>/dev/null || choice=""

        case $choice in
            1) r=0; start_services || r=$?; [[ $r -eq 2 ]] || press_enter ;;
            2) r=0; stop_services || r=$?; [[ $r -eq 2 ]] || press_enter ;;
            3) r=0; restart_services || r=$?; [[ $r -eq 2 ]] || press_enter ;;
            4) show_status; press_enter ;;
            5) view_logs ;;  # view_logs has its own loop, no press_enter needed
            6) user_management ;;  # user_management has its own loop
            7) cmd_donate; press_enter ;;
            8) cmd_doctor; press_enter ;;
            9) cmd_admin password; press_enter ;;
            10) cmd_update; press_enter ;;
            11) build_services; press_enter ;;
            12) migration_menu; press_enter ;;
            0|q|Q)
                echo ""
                info "🕊️ Goodbye! ✌️"
                exit 0
                ;;
            *)
                warn "Invalid choice"
                sleep 1
                ;;
        esac
    done
}

# =============================================================================
# Command Line Interface
# =============================================================================

show_usage() {
    echo "MoaV v${VERSION} - Multi-protocol Circumvention Stack"
    echo ""
    echo "Usage: moav [command] [options]"
    echo ""
    echo "Setup & Maintenance:"
    echo "  install               Install 'moav' command globally"
    echo "  uninstall [--wipe] [--yes] [--remove-images]  Remove containers + command"
    echo "                        (--wipe removes all data; --yes skips prompts; --remove-images also deletes images)"
    echo "  update [-b BRANCH]    Update MoaV (git pull + rebuild)"
    echo "  bootstrap [--yes]     First-time setup (keys, configs, service selection);"
    echo "                        --yes re-runs non-interactively (idempotent)"
    echo "  domainless            Enable domainless mode"
    echo "  check                 Run prerequisites check"
    echo "  doctor [CHECK]        Run diagnostics (e.g. 'doctor dns', 'doctor ports')"
    echo ""
    echo "Services:"
    echo "  start [PROFILE...]    Start services (default: saved profiles from .env)"
    echo "  stop [SERVICE...] [-r] Stop services (-r removes containers)"
    echo "  restart [SERVICE...]  Restart services"
    echo "  status                Show service status"
    echo "  logs [SERVICE...] [-n] View logs (follow mode, -n for snapshot)"
    echo "  profiles              Change default services for 'moav start'"
    echo "  build [SVC|PROFILE] [--no-cache]  Build services or profile"
    echo "  build --local [SVC|all]            Build locally (for blocked registries)"
    echo ""
    echo "Users:"
    echo "  users / user list     List all users"
    echo "  user add NAME [...] [-p]           Add user(s) (--package creates zip)"
    echo "  user add --batch N [--prefix P]    Batch create (user01, user02...)"
    echo "  user revoke NAME      Revoke a user"
    echo "  user package NAME     Create zip bundle for existing user"
    echo "  user base64 NAME      Base64 text-only bundle (for e2e / quick import)"
    echo "  admin password        Reset admin dashboard password"
    echo ""
    echo "Donate & Test:"
    echo "  donate                Donate VPN configs to MahsaNet/Psiphon/Snowflake"
    echo "  conduit [link|status] Psiphon Conduit claim link, QR & sharing guide"
    echo "  test USERNAME [-v]    Test connectivity for a user"
    echo "  client connect USER   Client mode (connect as user, exposes local proxy)"
    echo ""
    echo "Backup & Migration:"
    echo "  export [FILE]         Export config backup (keys, users, .env)"
    echo "  import FILE           Import config backup"
    echo "  migrate-ip NEW_IP     Update SERVER_IP and regenerate all configs"
    echo "  regenerate-users      Regenerate all user bundles with current .env"
    echo "  conduit-offsets CMD   Manage Conduit lifetime-offset auto-updater (install/uninstall/status)"
    echo "  cert [CMD]            TLS certificate status/renew + auto-renewal timer (install/uninstall)"
    echo "  setup-dns             Free port 53 for DNS tunnels (disables systemd-resolved)"
    echo "  switch-dns [NAME|off] Enable/disable DNS tunnel daemons (dnstt/slipstream/masterdns/xdns)"
    echo ""
    echo "Profiles: proxy, wireguard, amneziawg, dnstunnel, trusttunnel, xhttp, telegram,"
    echo "          admin, conduit, snowflake, monitoring, client, all"
    echo "Aliases:  wg→wireguard, awg→amneziawg, tg→telegram, conduit→psiphon-conduit"
    echo ""
    echo "Examples:"
    echo "  moav                                 # Interactive menu"
    echo "  moav start                           # Start default services"
    echo "  moav start proxy admin               # Start specific profiles"
    echo "  moav user add alice bob --package     # Add users with zip bundles"
    echo "  moav user add --batch 10 --prefix vip # Batch create vip01..vip10"
    echo "  moav donate                          # Donate configs to MahsaNet"
    echo "  moav doctor dns                      # Check DNS configuration"
    echo "  moav export                          # Backup to moav-backup-TIMESTAMP.tar.gz"
    echo "  moav migrate-ip 1.2.3.4              # Update to new server IP"
}

cmd_check() {
    print_header
    check_prerequisites
}


_conduit_sharing_explainer() {
    echo ""
    echo -e "  ${WHITE}How your Conduit helps people in Iran${NC}"
    echo ""
    echo "  1. Public pool (automatic — nothing to share)"
    echo "     While Conduit runs, it donates bandwidth to the Psiphon network."
    echo "     Psiphon app users worldwide — including in Iran — are brokered"
    echo "     through your server automatically. No link, no setup for them."
    echo ""
    echo "  2. Personal Pairing (share a private path with specific people)"
    echo "     Psiphon's Conduit lets you give friends/family a private, direct"
    echo "     path through your station. To do this:"
    echo "       a. Install the Ryve app (Psiphon's Conduit manager) on your phone."
    echo "       b. Import this station using the claim link below."
    echo "       c. In Ryve, enable Personal Pairing and generate a pairing link."
    echo "       d. Send that pairing link to people in Iran; they paste it into"
    echo "          the Psiphon app's \"pairing URL\" field to route through you."
    echo ""
    echo -e "  ${YELLOW}⚠ Security:${NC} the claim link / QR below embeds this Conduit's"
    echo -e "  ${YELLOW}  private key${NC} — it imports the station into YOUR OWN phone."
    echo "  Treat it like a password. Do NOT post it publicly: anyone with it"
    echo "  can take over your station. The public-safe link you share with"
    echo "  users is the Personal Pairing link generated inside Ryve (step c),"
    echo "  not this one. (Pairing-URL export lives in the Conduit/Ryve app; see"
    echo "  github.com/Psiphon-Inc/conduit/issues/205 for its status.)"
    echo ""
}

cmd_conduit() {
    local action="${1:-}"

    case "$action" in
        ""|link|--link|info|--info|show)
            print_section "Psiphon Conduit"
            _conduit_sharing_explainer
            cmd_donate_conduit_info
            ;;
        status|--status)
            local env_file="$SCRIPT_DIR/.env"
            print_section "Psiphon Conduit Status"
            echo ""
            local conduit_enabled
            conduit_enabled=$(get_env_val "ENABLE_CONDUIT" "$env_file" "true")
            if [[ "$conduit_enabled" != "true" ]]; then
                echo -e "  ${DIM}○ Disabled — enable in .env: ENABLE_CONDUIT=true${NC}"
                return 0
            fi
            local conduit_running=""
            docker compose ps psiphon-conduit --status running 2>/dev/null | tail -n +2 | grep -q . && conduit_running="yes"
            if [[ -n "$conduit_running" ]]; then
                local conduit_bw conduit_clients
                conduit_bw=$(get_env_val "CONDUIT_BANDWIDTH" "$env_file" "100")
                conduit_clients=$(get_env_val "CONDUIT_MAX_COMMON_CLIENTS" "$env_file" "200")
                echo -e "  ${GREEN}✓${NC} Running — ${conduit_bw} Mbps, ${conduit_clients} max clients"
                local cm
                cm=$(_query_conduit_metrics 2>/dev/null)
                if [[ -n "$cm" ]]; then
                    local c_conn c_up c_down
                    c_conn=$(echo "$cm" | awk '{print $1}')
                    c_up=$(echo "$cm" | awk '{print $2}')
                    c_down=$(echo "$cm" | awk '{print $3}')
                    echo -e "  Connected: ${CYAN}${c_conn}${NC} clients | Bandwidth: $(_format_bytes_sh "$c_up") ↑ / $(_format_bytes_sh "$c_down") ↓"
                fi
                echo -e "  ${DIM}Claim link: moav conduit link${NC}"
            else
                echo -e "  ${YELLOW}○${NC} Enabled but not running — start with: moav start conduit"
            fi
            ;;
        help|--help|-h)
            echo "Usage: moav conduit [command]"
            echo ""
            echo "Psiphon Conduit donates bandwidth to help people bypass censorship."
            echo ""
            echo "Commands:"
            echo "  link       Show the Ryve claim link + QR and how to share (default)"
            echo "  status     Show whether Conduit is running and live stats"
            echo "  help       Show this help"
            echo ""
            echo "Notes:"
            echo "  • Running Conduit already serves Psiphon users in Iran via the"
            echo "    public pool — no link needs to be shared for that."
            echo "  • The claim link embeds the private key (for your own phone's"
            echo "    Ryve app). Share with users only via Personal Pairing in Ryve."
            echo "  • Bandwidth/clients: moav donate setup. Status of all donation"
            echo "    services: moav donate status."
            ;;
        *)
            error "Unknown conduit command: $action"
            echo "Run 'moav conduit help' for usage."
            exit 1
            ;;
    esac
}

cmd_admin() {
    local action="${1:-}"

    case "$action" in
        password|reset-password|passwd)
            if [[ ! -f ".env" ]]; then
                error ".env file not found. Run 'moav setup' first."
                return 1
            fi

            echo ""
            echo -e "${WHITE}Reset admin dashboard password${NC}"
            echo "  Press Enter to generate a random password, or type your own"
            printf "  New password: "
            read -r new_password
            if [[ -z "$new_password" ]]; then
                new_password=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
            fi

            if grep -q "^ADMIN_PASSWORD=" .env 2>/dev/null; then
                sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=\"$new_password\"|" .env
            else
                echo "ADMIN_PASSWORD=\"$new_password\"" >> .env
            fi

            echo ""
            echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
            echo -e "  ${WHITE}New Admin Password:${NC} ${CYAN}$new_password${NC}"
            echo ""
            echo -e "  ${YELLOW}⚠ IMPORTANT: Save this password! It's also stored in .env${NC}"
            echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
            echo ""

            # Recreate admin container if running (restart won't pick up .env changes)
            if docker ps --filter "name=moav-admin" --filter "status=running" -q 2>/dev/null | grep -q .; then
                info "Recreating admin container to apply new password..."
                docker compose --profile admin up -d admin
                success "Admin container recreated with new password"
            else
                info "Admin container is not running. New password will take effect on next start."
            fi

            # Update Grafana password if running (Grafana stores password in its DB, env var is only used on first boot)
            if docker ps --filter "name=moav-grafana" --filter "status=running" -q 2>/dev/null | grep -q .; then
                info "Updating Grafana admin password..."
                if docker compose --profile monitoring exec -T grafana grafana cli admin reset-admin-password "$new_password" &>/dev/null; then
                    success "Grafana password updated"
                else
                    warn "Could not update Grafana password. You may need to reset it manually."
                fi
            fi
            ;;
        *)
            echo "Usage: moav admin <command>"
            echo ""
            echo "Commands:"
            echo "  password    Reset admin dashboard password"
            echo ""
            echo "Examples:"
            echo "  moav admin password           # Generate random password"
            ;;
    esac
}


cmd_profiles() {
    print_header

    print_section "Default Profiles"

    local current
    current=$(get_default_profiles)

    echo ""
    if [[ -n "$current" ]]; then
        echo -e "  Current defaults: ${GREEN}${current}${NC}"
        echo ""
        echo -e "  These profiles will start when you run ${CYAN}moav start${NC} without arguments."
    else
        echo -e "  ${YELLOW}No default profiles set${NC}"
        echo ""
        echo -e "  Running ${CYAN}moav start${NC} will start ${WHITE}all${NC} services."
    fi
    echo ""

    if confirm "Change default profiles?" "y"; then
        echo ""
        if select_profiles "save"; then
            echo ""
            if confirm "Build selected services now?" "n"; then
                info "Building..."
                compose_build $SELECTED_PROFILE_STRING build
                success "Build complete!"
            fi
        fi
    fi
}

cmd_start() {
    local profiles=""
    local valid_profiles="proxy wireguard amneziawg dnstunnel trusttunnel xhttp telegram admin conduit snowflake gooserelay monitoring client all setup"
    local force=false
    local args=()
    for arg in "$@"; do
        case "$arg" in
            --force|-f) force=true ;;
            *) args+=("$arg") ;;
        esac
    done
    set -- "${args[@]}"

    if [[ $# -eq 0 ]]; then
        # No arguments - check for DEFAULT_PROFILES in .env
        local defaults
        defaults=$(get_default_profiles)
        if [[ -n "$defaults" ]]; then
            # Drop stale entries whose ENABLE_* has since been flipped off (issue #106).
            local _filtered
            _filtered=$(filter_disabled_profiles "$defaults")
            if [[ "$_filtered" != "$defaults" ]]; then
                info "Using default profiles from .env: $_filtered"
            else
                info "Using default profiles from .env: $defaults"
            fi
            if [[ -z "$_filtered" ]]; then
                error "Every profile in DEFAULT_PROFILES is disabled in .env. Set at least one ENABLE_*=true or edit DEFAULT_PROFILES."
                return 1
            fi
            for p in $_filtered; do
                profiles+="--profile $p "
            done
        else
            # No defaults set - show interactive menu
            select_profiles "start"
            if [[ ${#SELECTED_PROFILES[@]} -eq 0 ]]; then
                info "No services selected"
                return 0
            fi
            for p in "${SELECTED_PROFILES[@]}"; do
                profiles+="--profile $p "
            done
        fi
    else
        local individual_services=""
        for p in "$@"; do
            # Resolve profile aliases (e.g., sing-box -> proxy)
            local resolved
            resolved=$(resolve_profile "$p")

            # `all` → expand to the ENABLE_*-derived enabled set (issue #106);
            # the `all` profile membership stays for build/logs/down enumeration.
            if [[ "$resolved" == "all" ]]; then
                local _all_expanded
                _all_expanded=$(derive_enabled_profiles "$SCRIPT_DIR/.env")
                if [[ -z "$_all_expanded" ]]; then
                    error "'all' resolved to an empty profile list — every ENABLE_* is false in .env."
                    return 1
                fi
                info "Expanding 'all' to enabled profiles: $_all_expanded"
                local _ap
                for _ap in $_all_expanded; do
                    profiles+="--profile $_ap "
                done
                continue
            fi

            # Check if it's a valid profile
            if echo "$valid_profiles" | grep -qw "$resolved"; then
                # Explicit name + ENABLE_*=false → 3-option prompt (--force bypasses).
                if ! $force && [[ "$(profile_enabled "$resolved" "$SCRIPT_DIR/.env")" != "true" ]]; then
                    local _decision
                    _decision=$(confirm_disabled_profile "$resolved" "$SCRIPT_DIR/.env")
                    case "$_decision" in
                        skip)
                            info "Skipped: $resolved"
                            continue
                            ;;
                        start-once|start-and-enable) ;;
                    esac
                fi
                profiles+="--profile $resolved "
            else
                # Try resolving as individual service name
                local svc
                svc=$(resolve_service "$p")
                individual_services+="$svc "
            fi
        done

        # If we have individual services but no profiles, figure out which profiles they need
        if [[ -n "$individual_services" ]] && [[ -z "$profiles" ]]; then
            info "Starting individual services: $individual_services"
            docker compose --profile all up -d $individual_services
            success "Services started!"
            auto_setup_conduit_offsets
            auto_setup_cert_renew
            return 0
        elif [[ -n "$individual_services" ]]; then
            warn "Ignoring individual services ($individual_services) when mixed with profiles"
        fi
    fi

    if [[ -z "$profiles" ]]; then
        error "No service selected"
        echo "Valid profiles: $valid_profiles"
        echo "Aliases: sing-box/singbox/reality/trojan/hysteria→proxy, wg→wireguard, awg→amneziawg, dns/dnstt/slip→dnstunnel, grafana/prometheus→monitoring"
        exit 1
    fi

    # Check if bootstrap has been run (skip for setup profile)
    if [[ ! "$profiles" =~ "setup" ]] && ! check_bootstrap; then
        warn "Bootstrap has not been run yet!"
        echo ""
        info "Bootstrap is required for first-time setup."
        echo "  It generates keys, obtains TLS certificates, and creates users."
        echo ""

        if confirm "Run bootstrap now?" "y"; then
            run_bootstrap || exit 1
            echo ""
        else
            error "Cannot start services without bootstrap."
            echo "  Run 'moav bootstrap' first, or use 'moav' for interactive setup."
            exit 1
        fi
    fi

    # Ensure CLASH_API_SECRET is configured for monitoring
    # Returns 1 if user declined monitoring when using 'all' profile
    local skip_monitoring=0
    ensure_clash_api_secret "$profiles" || skip_monitoring=1
    if [[ $skip_monitoring -eq 1 ]]; then
        # User declined monitoring — replace 'all' with derived enabled set (issue #106).
        local _enabled_s
        _enabled_s=$(derive_enabled_profiles "$SCRIPT_DIR/.env")
        profiles=""
        local _ps
        for _ps in $_enabled_s; do
            profiles+="--profile $_ps "
        done
    fi

    # Check port 53 conflicts for DNS tunnels
    local dnstt_enabled
    dnstt_enabled=$(get_env_val "ENABLE_DNSTT" "$SCRIPT_DIR/.env" "true")
    local slipstream_enabled
    slipstream_enabled=$(get_env_val "ENABLE_SLIPSTREAM" "$SCRIPT_DIR/.env" "true")
    local xdns_start_enabled
    xdns_start_enabled=$(get_env_val "ENABLE_XDNS" "$SCRIPT_DIR/.env" "true")

    # Check if any DNS tunnel needs port 53 (all go through dns-router now)
    local needs_port53=false
    local masterdns_start_enabled
    masterdns_start_enabled=$(get_env_val "ENABLE_MASTERDNS" "$SCRIPT_DIR/.env" "true")
    if echo "$profiles" | grep -qE "dnstunnel|all" && \
       [[ "$dnstt_enabled" == "true" || "$slipstream_enabled" == "true" || \
          "$masterdns_start_enabled" == "true" || "$xdns_start_enabled" == "true" ]]; then
        needs_port53=true
    fi

    if $needs_port53; then
        if port53_conflict_detected; then
            handle_port53_conflict
        fi
    fi

    info "Starting services..."
    docker compose $profiles up -d --remove-orphans
    success "Services started!"
    echo ""
    # Show admin URL if admin was started
    if echo "$profiles" | grep -qE "admin|all"; then
        echo -e "  ${CYAN}Admin Dashboard:${NC} $(get_admin_url)"
    fi
    # Show Grafana URL if monitoring was started
    if echo "$profiles" | grep -qE "monitoring|all"; then
        echo -e "  ${CYAN}Grafana:${NC}         $(get_grafana_url)"
        local grafana_cdn=$(get_grafana_cdn_url)
        if [[ -n "$grafana_cdn" ]]; then
            echo -e "  ${CYAN}Grafana (CDN):${NC}   $grafana_cdn"
        fi
    fi
    # Show Conduit sharing hint if conduit was started
    if echo "$profiles" | grep -qE "conduit|all"; then
        echo -e "  ${CYAN}Psiphon Conduit:${NC} serving Psiphon users (incl. Iran) via the public pool"
        echo -e "  ${DIM}                  Claim link, QR & sharing guide: moav conduit link${NC}"
    fi

    if echo "$profiles" | grep -qE "admin|monitoring|proxy|all"; then
        echo ""
    fi
    auto_setup_conduit_offsets
    auto_setup_cert_renew
}

# Resolve profile name aliases to actual docker-compose profile names
resolve_profile() {
    local profile="$1"
    case "$profile" in
        sing-box|singbox|sing|reality|trojan|hysteria|hysteria2|hy2)
            echo "proxy" ;;
        wg)
            echo "wireguard" ;;
        awg)
            echo "amneziawg" ;;
        dns|dnstt|slip|slipstream)
            echo "dnstunnel" ;;
        tg|mtproxy|telemt)
            echo "telegram" ;;
        xh|xray)
            echo "xhttp" ;;
        psiphon)
            echo "conduit" ;;
        grafana|grafana-proxy|grafana-cdn|prometheus|metrics)
            echo "monitoring" ;;
        *)
            echo "$profile" ;;
    esac
}

# Resolve service name aliases to actual docker-compose service names
resolve_service() {
    local svc="$1"
    case "$svc" in
        conduit|psiphon)              echo "psiphon-conduit" ;;
        singbox|sing|proxy|reality)   echo "sing-box" ;;
        ss|shadowsocks|outline)       echo "sing-box" ;;
        wg)                           echo "wireguard" ;;
        ws|tunnel)                    echo "wstunnel" ;;
        dns)                          echo "dnstt" ;;
        slip)                         echo "slipstream" ;;
        mdns|masterdns)               echo "masterdns" ;;
        goose|gooserelay|relay)       echo "gooserelay" ;;
        dns-router|dnsrouter)         echo "dns-router" ;;
        tg|mtproxy|telegram)          echo "telemt" ;;
        snow|tor)                     echo "snowflake" ;;
        # Monitoring services (pass through or resolve aliases)
        grafana-cdn)                  echo "grafana-proxy" ;;
        grafana|grafana-proxy|prometheus|cadvisor|node-exporter|clash-exporter|wireguard-exporter|snowflake-exporter|singbox-exporter)
            echo "$svc" ;;
        *)                            echo "$svc" ;;
    esac
}

# Resolve multiple service arguments
resolve_services() {
    local resolved=()
    for svc in "$@"; do
        resolved+=("$(resolve_service "$svc")")
    done
    echo "${resolved[@]}"
}

cmd_stop() {
    local remove_containers=false
    local args=()

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remove|-r)
                remove_containers=true
                shift
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#args[@]} -eq 0 ]] || [[ "${args[0]}" == "all" ]]; then
        if [[ "$remove_containers" == "true" ]]; then
            info "Stopping and removing all containers..."
            docker compose --profile all down
            success "All services stopped and removed!"
        else
            info "Stopping all services..."
            docker compose --profile all stop
            success "All services stopped!"
        fi
    else
        # Only treat as profile if it's an exact profile name
        # Service names like "grafana", "prometheus" stop just that service
        local profiles="proxy wireguard amneziawg dnstunnel trusttunnel admin conduit snowflake monitoring telegram"
        local profile_match=""
        for p in $profiles; do
            if [[ "${args[0]}" == "$p" ]]; then
                profile_match="$p"
                break
            fi
        done

        if [[ -n "$profile_match" ]]; then
            if [[ "$remove_containers" == "true" ]]; then
                info "Stopping and removing $profile_match profile..."
                docker compose --profile "$profile_match" down
            else
                info "Stopping $profile_match profile..."
                docker compose --profile "$profile_match" stop
            fi
            success "Profile $profile_match stopped!"
        else
            local services
            services=$(resolve_services "${args[@]}")
            if [[ -z "$services" ]]; then
                error "No valid services to stop"
                return 1
            fi
            if [[ "$remove_containers" == "true" ]]; then
                info "Stopping and removing: $services"
                docker compose rm -sf $services
            else
                info "Stopping: $services"
                docker compose stop $services
            fi
            success "Services stopped!"
        fi
    fi
}

cmd_restart() {
    if [[ $# -eq 0 ]] || [[ "$1" == "all" ]]; then
        info "Restarting all services..."
        docker compose --profile all restart
        success "All services restarted!"
    elif [[ $# -eq 1 ]]; then
        # Single argument - only treat as profile if it's an exact profile name
        # Service names like "grafana", "prometheus", "telemt" restart just that service
        local profiles="proxy wireguard amneziawg dnstunnel trusttunnel admin conduit snowflake monitoring telegram"
        local profile_match=""
        for p in $profiles; do
            if [[ "$1" == "$p" ]]; then
                profile_match="$p"
                break
            fi
        done

        if [[ -n "$profile_match" ]]; then
            info "Restarting $profile_match profile services..."
            docker compose --profile "$profile_match" restart
            success "Profile $profile_match restarted!"
        else
            local services
            services=$(resolve_services "$@")
            if [[ -z "$services" ]]; then
                error "No valid services to restart"
                return 1
            fi
            info "Restarting: $services"
            docker compose restart $services
            success "Services restarted!"
        fi
    else
        # Multiple arguments - resolve all as service names
        local services
        services=$(resolve_services "$@")
        if [[ -z "$services" ]]; then
            error "No valid services to restart"
            return 1
        fi
        info "Restarting: $services"
        docker compose restart $services
        success "Services restarted!"
    fi
}

cmd_status() {
    # Simple header without clearing terminal
    local singbox_ver wstunnel_ver conduit_ver branch
    singbox_ver=$(get_component_version "SINGBOX_VERSION" "1.13.12")
    wstunnel_ver=$(get_component_version "WSTUNNEL_VERSION" "10.6.1")
    conduit_ver=$(get_component_version "CONDUIT_VERSION" "1.2.0")
    branch=$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

    local version_str="v${VERSION}"
    if [[ -n "$branch" && "$branch" != "main" ]]; then
        version_str="v${VERSION} (${branch})"
    fi

    echo ""
    echo -e "${CYAN}MoaV${NC} ${version_str}  ${DIM}│${NC}  ${DIM}sing-box ${singbox_ver}  wstunnel ${wstunnel_ver}  conduit ${conduit_ver}${NC}"
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    show_status

    # Show admin and grafana URLs if running
    local running=$(get_running_services)
    local show_urls=0
    if echo "$running" | grep -q "admin"; then
        [[ $show_urls -eq 0 ]] && echo ""
        echo -e "  ${CYAN}Admin Dashboard:${NC} $(get_admin_url)"
        show_urls=1
    fi
    if echo "$running" | grep -q "grafana"; then
        [[ $show_urls -eq 0 ]] && echo ""
        echo -e "  ${CYAN}Grafana:${NC}         $(get_grafana_url)"
        local grafana_cdn=$(get_grafana_cdn_url)
        if [[ -n "$grafana_cdn" ]]; then
            echo -e "  ${CYAN}Grafana (CDN):${NC}   $grafana_cdn"
        fi
        show_urls=1
    fi


    # Show default profiles
    local defaults
    defaults=$(get_default_profiles)
    if [[ -n "$defaults" ]]; then
        info "Default profiles: ${WHITE}$defaults${NC}"
    fi
    echo ""
    echo -e "  ${CYAN}Commands:${NC} moav logs [service] | moav stop | moav restart | moav version"
}

cmd_logs() {
    local follow=true
    local tail_lines=100
    local services_to_log=""
    local profile_flags=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-follow|-n)
                follow=false
                shift
                ;;
            --tail=*)
                tail_lines="${1#*=}"
                shift
                ;;
            --tail)
                tail_lines="$2"
                shift 2
                ;;
            all)
                profile_flags="--profile all"
                shift
                ;;
            *)
                # Check if it's an exact profile name first
                local valid_profiles="proxy wireguard amneziawg dnstunnel trusttunnel xhttp telegram admin conduit snowflake gooserelay monitoring client all setup"
                if echo "$valid_profiles" | grep -qw "$1"; then
                    profile_flags="$profile_flags --profile $1"
                else
                    # Treat as service name (resolve aliases like slip → slipstream, tg → telemt)
                    local resolved_svc
                    resolved_svc=$(resolve_service "$1")
                    services_to_log="${services_to_log:+$services_to_log }$resolved_svc"
                fi
                shift
                ;;
        esac
    done

    # Build docker compose command
    local cmd="docker compose --ansi always"
    if [[ -z "$services_to_log" && -z "$profile_flags" ]]; then
        cmd="$cmd --profile all"
    elif [[ -n "$profile_flags" ]]; then
        cmd="$cmd $profile_flags"
    fi
    cmd="$cmd logs -t --tail $tail_lines"

    if [[ "$follow" == "true" ]]; then
        echo -e "${CYAN}Following logs (Ctrl+C to exit)...${NC}"
        echo ""
        $cmd -f $services_to_log | format_log_timestamps
    else
        $cmd $services_to_log | format_log_timestamps
    fi
}

cmd_users() {
    list_users
}

cmd_user() {
    local action="${1:-}"
    shift 1 2>/dev/null || shift $# # Shift past action to get remaining args
    local username="${1:-}"

    case "$action" in
        list|ls)
            list_users
            ;;
        add)
            # Check for batch mode or multiple usernames
            if [[ "${1:-}" == "--batch" ]] || [[ "${1:-}" == "-b" ]]; then
                # Batch mode - pass all args to script
                if [[ -x "./scripts/user-add.sh" ]]; then
                    ./scripts/user-add.sh "$@"
                else
                    error "User add script not found"
                    exit 1
                fi
            elif [[ -z "${1:-}" ]]; then
                error "Usage: moav user add USERNAME [USERNAME2...] [--package]"
                error "       moav user add --batch N [--prefix NAME] [--package]"
                exit 1
            else
                # Single or multiple usernames - validate each, then pass all to script
                local usernames=()
                local flags=()
                for arg in "$@"; do
                    if [[ "$arg" == --* ]] || [[ "$arg" == -* ]]; then
                        flags+=("$arg")
                    else
                        if [[ ! "$arg" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                            error "Invalid username '$arg'. Use only letters, numbers, underscores, and hyphens"
                            exit 1
                        fi
                        usernames+=("$arg")
                    fi
                done
                if [[ ${#usernames[@]} -eq 0 ]]; then
                    error "No usernames provided"
                    exit 1
                fi
                if [[ -x "./scripts/user-add.sh" ]]; then
                    ./scripts/user-add.sh "${usernames[@]}" "${flags[@]}"
                else
                    error "User add script not found"
                    exit 1
                fi
            fi
            ;;
        revoke|rm|remove|delete)
            if [[ -z "${1:-}" ]]; then
                error "Usage: moav user revoke USERNAME [USERNAME2...]"
                exit 1
            fi
            if [[ ! -x "./scripts/user-revoke.sh" ]]; then
                error "User revoke script not found"
                exit 1
            fi
            for u in "$@"; do
                ./scripts/user-revoke.sh "$u" || true
            done
            ;;
        package|pkg)
            if [[ -z "$username" ]]; then
                error "Usage: moav user package USERNAME"
                exit 1
            fi
            if [[ -x "./scripts/user-package.sh" ]]; then
                ./scripts/user-package.sh "$username"
            else
                error "User package script not found"
                exit 1
            fi
            ;;
        base64|b64)
            cmd_user_base64 "$username"
            ;;
        *)
            error "Usage: moav user [list|add|revoke|package|base64] [USERNAME]"
            exit 1
            ;;
    esac
}

# Build via docker compose with RAM-aware concurrency. Docker's bake builder
# fans every image out in parallel, which OOMs / trips BuildKit's solve deadline
# ("context deadline exceeded") on low-RAM hosts (e.g. a 2GB VPS building ~19
# images at once). Tier the concurrency to MemTotal so small boxes build
# serially and reliably while big boxes stay fast. Pass everything that would
# follow `docker compose` (e.g. `--profile all build foo`).
#
# Override the auto-tier with MOAV_BUILD_PARALLEL=N (1 = serial, 0 = leave
# Docker's default/unbounded behavior).
compose_build() {
    local total_mb limit
    total_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)

    if [[ -n "${MOAV_BUILD_PARALLEL:-}" ]]; then
        limit="$MOAV_BUILD_PARALLEL"
    elif [[ "$total_mb" -gt 0 && "$total_mb" -le 3072 ]]; then
        limit=1          # <=3GB: serial — one heavy Go compile at a time
    elif [[ "$total_mb" -gt 0 && "$total_mb" -le 6144 ]]; then
        limit=2          # 3-6GB: two at a time
    else
        limit=0          # >6GB or unknown: leave Docker defaults (bake/parallel)
    fi

    if [[ "$limit" =~ ^[0-9]+$ ]] && [[ "$limit" -ge 1 ]]; then
        # COMPOSE_BAKE=false selects the classic builder that honors
        # COMPOSE_PARALLEL_LIMIT; the bake builder ignores it and parallelizes.
        info "Build concurrency limited to ${limit} (RAM ${total_mb}MB; set MOAV_BUILD_PARALLEL=N to override)" >&2
        COMPOSE_BAKE=false COMPOSE_PARALLEL_LIMIT="$limit" docker compose "$@"
    else
        docker compose "$@"
    fi
}

cmd_build() {
    local no_cache=""
    local build_local=""
    local services_args=()

    # Parse arguments
    for arg in "$@"; do
        case "$arg" in
            --no-cache) no_cache="--no-cache" ;;
            --local) build_local="true" ;;
            *) services_args+=("$arg") ;;
        esac
    done

    # Check if .env exists
    if [[ ! -f ".env" ]]; then
        echo ""
        warn "No .env file found. Build may fail or show warnings about missing variables."
        echo ""
        echo "  You have two options:"
        echo -e "    1. Run ${CYAN}moav bootstrap${NC} first to set up configuration"
        echo "    2. Copy .env.example to .env and configure manually"
        echo ""
        if ! confirm "Continue building anyway?" "n"; then
            echo ""
            info "Run 'moav bootstrap' or 'cp .env.example .env' first"
            return 0
        fi
        echo ""
    fi

    # Handle --local: build images locally from Dockerfiles
    if [[ "$build_local" == "true" ]]; then
        build_local_images "$no_cache" "${services_args[@]}"
        return $?
    fi

    if [[ ${#services_args[@]} -eq 0 ]] || [[ "${services_args[0]}" == "all" ]]; then
        info "Building all services${no_cache:+ (no cache)}..."
        # Go services compile from source and download modules from proxy.golang.org.
        # Building them in parallel with 10+ other images saturates the network,
        # causing TLS handshake timeouts on module downloads.
        # Fix: build Go services sequentially first, then everything else in parallel.
        local go_services="amneziawg dnstt dns-router snowflake"
        local buildable_services remaining_services

        # Get only services that have build: configs (excludes image-only services)
        buildable_services=$(docker compose --profile all config --format json 2>/dev/null \
            | jq -r '.services | to_entries[] | select(.value.build != null) | .key' 2>/dev/null) \
            || buildable_services=$(docker compose --profile all config --services 2>/dev/null)

        # Phase 1: Build Go-compilation services one at a time
        info "Phase 1/2: Building Go services (sequential)..."
        for svc in $go_services; do
            if echo "$buildable_services" | grep -q "^${svc}$"; then
                info "  Building ${svc}..."
                compose_build --profile all build $no_cache "$svc"
            fi
        done

        # Phase 2: Build remaining buildable services in parallel
        remaining_services=$(echo "$buildable_services" | grep -vE "^($(echo $go_services | tr ' ' '|'))$" | tr '\n' ' ')
        info "Phase 2/2: Building remaining services ($(echo $remaining_services | wc -w | tr -d ' ') services)..."
        compose_build --profile all build $no_cache $remaining_services
        success "All services built!"
    else
        # Resolve all arguments: each can be a profile name or a service name
        local profiles="proxy wireguard amneziawg dnstunnel trusttunnel admin conduit snowflake monitoring"
        local matched_profiles=()
        local remaining_args=()

        for arg in "${services_args[@]}"; do
            local resolved_arg
            resolved_arg=$(resolve_profile "$arg")
            local is_profile=""
            for p in $profiles; do
                if [[ "$resolved_arg" == "$p" ]]; then
                    matched_profiles+=("$p")
                    is_profile="true"
                    break
                fi
            done
            if [[ -z "$is_profile" ]]; then
                remaining_args+=("$arg")
            fi
        done

        # Build matched profiles
        for profile in "${matched_profiles[@]}"; do
            info "Building $profile profile${no_cache:+ (no cache)}..."
            compose_build --profile "$profile" build $no_cache
            success "Profile $profile built!"
        done

        # Build remaining services (non-profile args)
        if [[ ${#remaining_args[@]} -gt 0 ]]; then
            local services
            services=$(resolve_services "${remaining_args[@]}")
            # Remove empty values and trim whitespace
            services=$(echo "$services" | xargs)
            if [[ -n "$services" ]]; then
                # Check if any services are image-only (need --local build)
                local compose_services=()
                local local_services=()
                for svc in $services; do
                    if _local_build_info "$svc" >/dev/null 2>&1; then
                        local_services+=("$svc")
                    else
                        compose_services+=("$svc")
                    fi
                done
                # Build compose services normally
                if [[ ${#compose_services[@]} -gt 0 ]]; then
                    info "Building: ${compose_services[*]}${no_cache:+ (no cache)}"
                    compose_build --profile all build $no_cache "${compose_services[@]}"
                    success "Build complete!"
                fi
                # Auto-redirect image-only services to local build
                if [[ ${#local_services[@]} -gt 0 ]]; then
                    info "Building locally: ${local_services[*]} (image-only services)"
                    build_local_images "$no_cache" "${local_services[@]}"
                fi
            fi
        fi

        # Nothing matched at all
        if [[ ${#matched_profiles[@]} -eq 0 && ${#remaining_args[@]} -eq 0 ]]; then
            info "No buildable services specified"
            return 0
        fi
    fi
}

# Map of services that can be built locally
# Format: "dockerfile|image_tag|image_env_var|version_env_var|version_arg|description"
ALL_LOCAL_BUILD_SERVICES="cadvisor clash-exporter prometheus grafana node-exporter nginx certbot"

_local_build_info() {
    case "$1" in
        cadvisor)       echo "dockerfiles/Dockerfile.cadvisor|moav-cadvisor:local|IMAGE_CADVISOR|CADVISOR_VERSION|CADVISOR_VERSION|cAdvisor container metrics (gcr.io)" ;;
        clash-exporter) echo "dockerfiles/Dockerfile.clash-exporter|moav-clash-exporter:local|IMAGE_CLASH_EXPORTER|CLASH_EXPORTER_VERSION|CLASH_EXPORTER_VERSION|Clash API exporter (ghcr.io)" ;;
        prometheus)     echo "dockerfiles/Dockerfile.prometheus|moav-prometheus:local|IMAGE_PROMETHEUS|PROMETHEUS_VERSION|PROMETHEUS_VERSION|Prometheus time-series DB" ;;
        grafana)        echo "dockerfiles/Dockerfile.grafana|moav-grafana:local|IMAGE_GRAFANA|GRAFANA_VERSION|GRAFANA_VERSION|Grafana dashboards" ;;
        node-exporter)  echo "dockerfiles/Dockerfile.node-exporter|moav-node-exporter:local|IMAGE_NODE_EXPORTER|NODE_EXPORTER_VERSION|NODE_EXPORTER_VERSION|Node system metrics" ;;
        nginx)          echo "dockerfiles/Dockerfile.nginx|moav-nginx:local|IMAGE_NGINX||NGINX_VERSION|Nginx web server" ;;
        certbot)        echo "dockerfiles/Dockerfile.certbot|moav-certbot:local|IMAGE_CERTBOT||CERTBOT_VERSION|Let's Encrypt client" ;;
        *) return 1 ;;
    esac
}

# Default services to build with --local (commonly blocked registries)
DEFAULT_LOCAL_BUILDS="cadvisor clash-exporter"

# Build images locally for regions with blocked registries
build_local_images() {
    local no_cache="${1:-}"
    shift
    local services_to_build=("$@")
    local env_file=".env"
    local built_count=0

    print_section "Building Local Images"
    echo ""
    echo "This builds images from source for regions where container registries are blocked."
    echo ""

    # If no services specified, use defaults (commonly blocked)
    if [[ ${#services_to_build[@]} -eq 0 ]]; then
        read -ra services_to_build <<< "$DEFAULT_LOCAL_BUILDS"
        echo "Building default images (gcr.io/ghcr.io - commonly blocked):"
        for svc in "${services_to_build[@]}"; do
            echo "  - $svc"
        done
    elif [[ "${services_to_build[0]}" == "all" ]]; then
        # First, build all services that use docker-compose build
        echo "Step 1: Building all docker-compose services..."
        echo ""
        if compose_build --profile all build $no_cache; then
            success "Docker-compose services built!"
        else
            error "Failed to build some docker-compose services"
        fi
        echo ""

        # Then build external images
        echo "Step 2: Building external images locally..."
        read -ra services_to_build <<< "$ALL_LOCAL_BUILD_SERVICES"
        echo "Images to build:"
        for svc in "${services_to_build[@]}"; do
            echo "  - $svc"
        done
    else
        echo "Building specified images:"
        for svc in "${services_to_build[@]}"; do
            echo "  - $svc"
        done
    fi
    echo ""

    # Build each service
    for service in "${services_to_build[@]}"; do
        local build_info
        build_info=$(_local_build_info "$service" 2>/dev/null) || true

        if [[ -z "$build_info" ]]; then
            warn "Unknown service for local build: $service"
            echo "Available services: $ALL_LOCAL_BUILD_SERVICES"
            continue
        fi

        # Parse build info (dockerfile|image_tag|image_env_var|version_env_var|version_arg|description)
        IFS='|' read -r dockerfile image_tag image_env_var version_env_var version_arg description <<< "$build_info"

        # Check Dockerfile exists
        if [[ ! -f "$dockerfile" ]]; then
            error "Dockerfile not found: $dockerfile"
            continue
        fi

        # Get version from .env if available
        local version_value=""
        local build_args=""
        if [[ -n "$version_env_var" ]] && [[ -f "$env_file" ]]; then
            version_value=$(grep "^${version_env_var}=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || true)
            if [[ -n "$version_value" ]] && [[ -n "$version_arg" ]]; then
                build_args="--build-arg ${version_arg}=${version_value}"
            fi
        fi

        info "Building $service ($description)${version_value:+ v$version_value}..."
        if docker build $no_cache $build_args -f "$dockerfile" -t "$image_tag" .; then
            success "$service built: $image_tag"
            built_count=$((built_count + 1))

            # Update .env to use local image
            if [[ -f "$env_file" ]] && [[ -n "$image_env_var" ]]; then
                update_env_var "$env_file" "$image_env_var" "$image_tag"
            fi
        else
            error "Failed to build $service"
        fi
        echo ""
    done

    if [[ $built_count -eq 0 ]]; then
        error "No images were built successfully"
        return 1
    fi

    success "$built_count local image(s) built successfully!"
    echo ""
    echo "Your .env has been updated to use the local images."
    echo "Run 'moav start' to use them."
    echo ""
    echo "To see all available images for local build:"
    echo "  moav build --local --list"
}

# Strip scheme / user@ / path / port / whitespace from a domain input; lowercase.
# Echoes the bare hostname (or "" if nothing usable remains).
sanitize_domain() {
    local d="$1"
    # Scheme
    d="${d#http://}"; d="${d#https://}"
    d="${d#HTTP://}"; d="${d#HTTPS://}"
    # user@host
    d="${d##*@}"
    # /path
    d="${d%%/*}"
    # :port
    d="${d%%:*}"
    # Strip all whitespace (hostnames have none).
    d="${d// /}"
    d="${d//$'\t'/}"
    # lowercase
    echo "$d" | tr '[:upper:]' '[:lower:]'
}

# True if $1 looks like a hostname (has a dot, only [a-z0-9.-], no leading/
# trailing punctuation, no consecutive dots).
is_valid_domain() {
    local d="$1"
    [[ -n "$d" ]] || return 1
    [[ "$d" == *.* ]] || return 1
    [[ "$d" =~ ^[a-z0-9.-]+$ ]] || return 1
    [[ "$d" != *..* ]] || return 1
    [[ "${d:0:1}" =~ [a-z0-9] ]] || return 1
    [[ "${d: -1}" =~ [a-z0-9] ]] || return 1
    return 0
}

# Helper: set <var>=<value> in .env. Prefers replacing an existing line
# (active or commented `#X=` / `# X=`); appends only if neither exists.
update_env_var() {
    local env_file="$1"
    local var_name="$2"
    local var_value="$3"

    if grep -q "^${var_name}=" "$env_file" 2>/dev/null; then
        sed -i.bak "s|^${var_name}=.*|${var_name}=${var_value}|" "$env_file"
    elif grep -qE "^#[[:space:]]*${var_name}=" "$env_file" 2>/dev/null; then
        # Uncomment + set — .env.example has both "#X=" and "# X=" styles.
        sed -i.bak "s|^#[[:space:]]*${var_name}=.*|${var_name}=${var_value}|" "$env_file"
    else
        echo "${var_name}=${var_value}" >> "$env_file"
    fi
    rm -f "$env_file.bak"
}

# =============================================================================
# Client Commands
# =============================================================================

# `moav user base64 <user>` — emit base64 of a text-only bundle (the config text
# files + subscription.txt; excludes the QR PNGs and README.html, which are the
# bulk). Paste it into moav-client's e2e `bundle_b64` input, or use it for a
# quick client import:  moav user base64 alice | pbcopy
cmd_user_base64() {
    local user="${1:-}"
    if [[ -z "$user" ]]; then
        error "Usage: moav user base64 USERNAME"
        {
            echo ""
            echo "Emits base64 of a text-only bundle (configs + subscription.txt; no QR PNGs / README)."
            echo "Paste into moav-client's e2e 'bundle_b64' input, or:  moav user base64 alice | pbcopy"
            echo ""
            echo "Available users:"
            ls -1 outputs/bundles/ 2>/dev/null || echo "  No users found"
        } >&2
        exit 1
    fi
    local bundle="outputs/bundles/$user"
    [[ -d "$bundle" ]] || { error "User bundle not found: $bundle"; exit 1; }
    command -v zip >/dev/null 2>&1 || { error "zip is required for 'moav user base64'"; exit 1; }

    local tmp zip b64 size
    tmp="$(mktemp -d)"
    zip="$tmp/${user}.zip"
    # Keep everything except the QR images and the rendered guide — i.e. the
    # text/config files a client actually imports.
    if ! ( cd outputs/bundles && zip -q -r "$zip" "$user" \
             -x "*.png" -x "*/README.html" -x "*.DS_Store" ); then
        rm -rf "$tmp"; error "failed to build text-only bundle zip"; exit 1
    fi
    # Read from stdin (both GNU and BSD base64 do) and strip any line wrapping —
    # portable across Linux servers and macOS dev boxes.
    b64="$(base64 < "$zip" | tr -d '\n')"
    size="$(wc -c < "$zip" | tr -d ' ')"
    rm -rf "$tmp"
    echo "[moav] text-only bundle for '$user': ${size}B zipped -> ${#b64} base64 chars" >&2
    printf '%s\n' "$b64"
}

cmd_test() {
    local user=""
    local json_flag=""
    local verbose_flag=""

    # Parse flags
    for arg in "$@"; do
        case "$arg" in
            --json) json_flag="--json" ;;
            -v|--verbose) verbose_flag="--verbose" ;;
            -*) error "Unknown flag: $arg"; exit 1 ;;
            *) [[ -z "$user" ]] && user="$arg" ;;
        esac
    done

    if [[ -z "$user" ]]; then
        error "Usage: moav test USERNAME [--json] [-v|--verbose]"
        echo ""
        echo "Available users:"
        ls -1 outputs/bundles/ 2>/dev/null || echo "  No users found"
        exit 1
    fi

    local bundle_path="outputs/bundles/$user"
    if [[ ! -d "$bundle_path" ]]; then
        error "User bundle not found: $bundle_path"
        exit 1
    fi

    info "Testing connectivity for user: $user"

    # Always (re)build the client image. Docker's layer cache makes this a
    # near-noop when nothing changed, but a plain "skip if it exists" check
    # silently reused a stale image — so `moav test` missed client Dockerfile /
    # pinned-version changes (e.g. a new sing-box after `moav update`).
    info "Building client image (cached if unchanged)..."
    compose_build --profile client build client

    # Run test (mount bundle + dnstt/slipstream outputs)
    docker run --rm \
        -v "$(pwd)/$bundle_path:/config:ro" \
        -v "$(pwd)/outputs/dnstt:/dnstt:ro" \
        -v "$(pwd)/outputs/slipstream:/slipstream:ro" \
        -e ENABLE_DEPRECATED_WIREGUARD_OUTBOUND=true \
        moav-client --test $json_flag $verbose_flag
}

cmd_client() {
    local action="${1:-}"
    shift || true

    case "$action" in
        test)
            cmd_test "$@"
            ;;
        connect)
            local user=""
            local protocol="auto"

            # Parse arguments
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --protocol|-p)
                        protocol="${2:-auto}"
                        shift 2
                        ;;
                    --*)
                        error "Unknown option: $1"
                        exit 1
                        ;;
                    *)
                        [[ -z "$user" ]] && user="$1"
                        shift
                        ;;
                esac
            done

            if [[ -z "$user" ]]; then
                error "Usage: moav client connect USERNAME [--protocol PROTOCOL]"
                echo ""
                echo "Protocols: auto, reality, trojan, hysteria2, wireguard, psiphon, tor, dnstt, slipstream"
                echo ""
                echo "Available users:"
                ls -1 outputs/bundles/ 2>/dev/null || echo "  No users found"
                exit 1
            fi

            local bundle_path="outputs/bundles/$user"
            if [[ ! -d "$bundle_path" ]]; then
                error "User bundle not found: $bundle_path"
                exit 1
            fi

            # Read ports from .env or use alternative defaults (to avoid server conflicts)
            local socks_port="10800"
            local http_port="18080"

            if [[ -f ".env" ]]; then
                local env_socks=$(grep -E "^CLIENT_SOCKS_PORT=" .env 2>/dev/null | cut -d= -f2 | tr -d ' "')
                local env_http=$(grep -E "^CLIENT_HTTP_PORT=" .env 2>/dev/null | cut -d= -f2 | tr -d ' "')
                [[ -n "$env_socks" ]] && socks_port="$env_socks"
                [[ -n "$env_http" ]] && http_port="$env_http"
            fi

            info "Connecting as user: $user (protocol: $protocol)"
            info "SOCKS5 proxy will be available at localhost:$socks_port"
            info "HTTP proxy will be available at localhost:$http_port"

            # Build client image if needed
            if ! docker images --format "{{.Repository}}" 2>/dev/null | grep -q "^moav-client$"; then
                info "Building client image..."
                compose_build --profile client build client
            fi

            # Run client in foreground (mount bundle + dnstt/slipstream outputs)
            docker run --rm -it \
                -p "$socks_port:1080" \
                -p "$http_port:8080" \
                -v "$(pwd)/$bundle_path:/config:ro" \
                -v "$(pwd)/outputs/dnstt:/dnstt:ro" \
                -v "$(pwd)/outputs/slipstream:/slipstream:ro" \
                -e ENABLE_DEPRECATED_WIREGUARD_OUTBOUND=true \
                moav-client --connect -p "$protocol"
            ;;
        build)
            info "Building client image..."
            compose_build --profile client build client
            success "Client image built!"
            ;;
        *)
            echo "Usage: moav client <command> [options]"
            echo ""
            echo "Commands:"
            echo "  test USERNAME [--json]        Test connectivity for a user"
            echo "  connect USERNAME [PROTOCOL]   Connect and expose local proxy"
            echo "  build                         Build the client image"
            echo ""
            echo "Protocols: auto, reality, trojan, hysteria2, wireguard, psiphon, tor, dnstt"
            echo ""
            echo "Examples:"
            echo "  moav client test joe              # Test all protocols for user joe"
            echo "  moav client test joe --json       # Output results as JSON"
            echo "  moav client connect joe           # Connect using auto-detection"
            echo "  moav client connect joe reality   # Connect using Reality protocol"
            ;;
    esac
}


cmd_regenerate_users() {
    print_section "Regenerate User Bundles"

    info "This will regenerate all user config bundles using current .env settings."
    echo "  - Credentials (UUIDs, passwords, keys) remain unchanged"
    echo "  - IP and domain will be updated from .env"
    echo ""

    # Check if bootstrap has been run
    if ! check_bootstrap; then
        error "Bootstrap has not been run. Run 'moav bootstrap' first."
        exit 1
    fi

    # Load current settings
    local server_ip=$(grep -E '^SERVER_IP=' .env 2>/dev/null | cut -d= -f2 | tr -d '"')
    local server_ipv6=$(grep -E '^SERVER_IPV6=' .env 2>/dev/null | cut -d= -f2 | tr -d '"')
    local domain=$(grep -E '^DOMAIN=' .env 2>/dev/null | cut -d= -f2 | tr -d '"')

    # Auto-detect IP if not set
    if [[ -z "$server_ip" ]]; then
        server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
        if [[ -n "$server_ip" ]]; then
            info "SERVER_IP not set, using detected IP: $server_ip"
        else
            error "Could not determine server IP. Set SERVER_IP in .env"
            exit 1
        fi
    fi

    # Auto-detect IPv6 if not set or disabled
    if [[ -z "$server_ipv6" ]] && [[ "$server_ipv6" != "disabled" ]]; then
        server_ipv6=$(curl -6 -s --max-time 3 https://api6.ipify.org 2>/dev/null || echo "")
    fi
    [[ "$server_ipv6" == "disabled" ]] && server_ipv6=""

    echo -e "  Server IP:   ${CYAN}$server_ip${NC}"
    if [[ -n "$server_ipv6" ]]; then
        echo -e "  Server IPv6: ${CYAN}$server_ipv6${NC}"
    fi
    echo -e "  Domain:      ${CYAN}${domain:-not set}${NC}"

    # Show CDN domain if configured
    local cdn_subdomain_preview=$(grep -E '^CDN_SUBDOMAIN=' .env 2>/dev/null | cut -d= -f2 | tr -d '"')
    if [[ -n "$cdn_subdomain_preview" && -n "$domain" ]]; then
        echo -e "  CDN Domain:  ${CYAN}${cdn_subdomain_preview}.${domain}${NC}"
    fi
    echo ""

    if ! confirm "Regenerate all user bundles?" "y"; then
        info "Cancelled."
        exit 0
    fi

    echo ""

    # Find existing users from bundles directory
    info "Finding existing users..."

    local user_count=0
    local users_found=""

    # List users from the outputs/bundles directory (the authoritative source)
    if [[ -d "outputs/bundles" ]]; then
        for user_dir in outputs/bundles/*/; do
            if [[ -d "$user_dir" ]]; then
                local username=$(basename "$user_dir")
                # Skip zip file extractions and temp directories
                [[ "$username" == *-configs ]] && continue
                [[ "$username" == *-moav-configs ]] && continue
                [[ "$username" == "." ]] && continue
                users_found="$users_found $username"
            fi
        done
        users_found=$(echo "$users_found" | xargs)  # Trim whitespace
    fi

    if [[ -z "$users_found" ]]; then
        warn "No users found in outputs/bundles/."
        echo "  Users are created during bootstrap or with 'moav user add'"
        exit 0
    fi

    echo "  Found users: $users_found"
    echo ""

    info "Regenerating bundles..."

    # Construct CDN_DOMAIN from CDN_SUBDOMAIN + DOMAIN if not explicitly set
    local cdn_domain=$(grep -E '^CDN_DOMAIN=' .env 2>/dev/null | cut -d= -f2 | tr -d '"')
    local cdn_subdomain=$(grep -E '^CDN_SUBDOMAIN=' .env 2>/dev/null | cut -d= -f2 | tr -d '"')
    if [[ -z "$cdn_domain" && -n "$cdn_subdomain" && -n "$domain" ]]; then
        cdn_domain="${cdn_subdomain}.${domain}"
    fi
    local cdn_ws_path=$(grep -E '^CDN_WS_PATH=' .env 2>/dev/null | cut -d= -f2 | tr -d '"')
    # Fall back to bootstrap-generated path from state
    if [[ -z "$cdn_ws_path" ]]; then
        cdn_ws_path=$(docker run --rm -v moav_moav_state:/state alpine cat /state/keys/cdn.env 2>/dev/null | grep '^CDN_WS_PATH=' | cut -d= -f2 || true)
    fi
    cdn_ws_path="${cdn_ws_path:-/ws}"
    local cdn_transport=$(grep -E '^CDN_TRANSPORT=' .env 2>/dev/null | cut -d= -f2 | tr -d '"')
    cdn_transport="${cdn_transport:-httpupgrade}"
    local cdn_sni=$(grep -E '^CDN_SNI=' .env 2>/dev/null | cut -d= -f2 | tr -d '"')
    cdn_sni="${cdn_sni:-${domain}}"
    local cdn_address=$(grep -E '^CDN_ADDRESS=' .env 2>/dev/null | cut -d= -f2 | tr -d '"')
    cdn_address="${cdn_address:-${cdn_domain}}"

    # Load ENABLE_* settings from .env
    local enable_reality=$(get_env_val "ENABLE_REALITY" .env "true")
    local enable_trojan=$(get_env_val "ENABLE_TROJAN" .env "true")
    local enable_anytls=$(get_env_val "ENABLE_ANYTLS" .env "false")
    local port_anytls=$(get_env_val "PORT_ANYTLS" .env "8445")
    local enable_hysteria2=$(get_env_val "ENABLE_HYSTERIA2" .env "true")
    local enable_wireguard=$(get_env_val "ENABLE_WIREGUARD" .env "true")
    local enable_amneziawg=$(get_env_val "ENABLE_AMNEZIAWG" .env "true")
    local enable_dnstt=$(get_env_val "ENABLE_DNSTT" .env "true")
    local enable_slipstream=$(get_env_val "ENABLE_SLIPSTREAM" .env "true")
    local slipstream_subdomain=$(get_env_val "SLIPSTREAM_SUBDOMAIN" .env "s")
    local enable_masterdns=$(get_env_val "ENABLE_MASTERDNS" .env "true")
    local masterdns_subdomain=$(get_env_val "MASTERDNS_SUBDOMAIN" .env "m")
    local masterdns_public_subdomain=$(get_env_val "MASTERDNS_PUBLIC_SUBDOMAIN" .env "")
    local enable_gooserelay=$(get_env_val "ENABLE_GOOSERELAY" .env "false")
    local port_goose=$(get_env_val "PORT_GOOSE" .env "8444")
    local enable_trusttunnel=$(get_env_val "ENABLE_TRUSTTUNNEL" .env "true")
    local enable_xhttp=$(get_env_val "ENABLE_XHTTP" .env "true")
    local port_xhttp=$(get_env_val "PORT_XHTTP" .env "2096")
    local xhttp_reality_target=$(get_env_val "XHTTP_REALITY_TARGET" .env "dl.google.com:443")
    local enable_telemt=$(get_env_val "ENABLE_TELEMT" .env "true")
    local telemt_tls_domain=$(get_env_val "TELEMT_TLS_DOMAIN" .env "dl.google.com")
    local telemt_max_tcp_conns=$(get_env_val "TELEMT_MAX_TCP_CONNS" .env "100")
    local telemt_max_unique_ips=$(get_env_val "TELEMT_MAX_UNIQUE_IPS" .env "10")
    local port_telemt=$(get_env_val "PORT_TELEMT" .env "993")
    local enable_ss=$(get_env_val "ENABLE_SS" .env "false")
    local port_ss=$(get_env_val "PORT_SS" .env "8388")
    local ss_method=$(get_env_val "SS_METHOD" .env "2022-blake3-aes-128-gcm")
    # DNS-tunnel subdomain/port fields — without these, regenerated bundles fall
    # back to defaults (t/x/53) and drift from the active .env (issue #98)
    local dnstt_subdomain=$(get_env_val "DNSTT_SUBDOMAIN" .env "t")
    local enable_xdns=$(get_env_val "ENABLE_XDNS" .env "false")
    local xdns_subdomain=$(get_env_val "XDNS_SUBDOMAIN" .env "x")
    local xdns_mtu=$(get_env_val "XDNS_MTU" .env "35")
    local xdns_resolvers=$(get_env_val "XDNS_RESOLVERS" .env "1.1.1.1,8.8.8.8")
    local port_dns=$(get_env_val "PORT_DNS" .env "53")
    local port_xdns=$(get_env_val "PORT_XDNS" .env "53")

    # ONE container run for the whole job, via the shared provisioning path
    # (lib/provision.sh `provision_all_users force`) — the SAME implementation
    # bootstrap.sh uses, so the two can no longer drift. This replaces a
    # per-user `docker compose run` (which re-passed ~50 -e vars for every
    # user) plus a second, separate run for the reconcile whose shell lacked
    # `set -e` while bootstrap's had it — exactly the divergence that made
    # "regenerate-users works but bootstrap aborts" possible.
    echo "  Regenerating bundles + reconciling server configs..."
    if docker compose run --rm -T \
            -e "SERVER_IP=$server_ip" \
            -e "SERVER_IPV6=$server_ipv6" \
            -e "DOMAIN=$domain" \
            -e "CDN_SUBDOMAIN=$cdn_subdomain" \
            -e "CDN_DOMAIN=$cdn_domain" \
            -e "CDN_WS_PATH=$cdn_ws_path" \
            -e "CDN_TRANSPORT=$cdn_transport" \
            -e "CDN_SNI=$cdn_sni" \
            -e "CDN_ADDRESS=$cdn_address" \
            -e "ENABLE_REALITY=${enable_reality:-true}" \
            -e "ENABLE_TROJAN=${enable_trojan:-true}" \
            -e "ENABLE_ANYTLS=${enable_anytls:-false}" \
            -e "PORT_ANYTLS=${port_anytls:-8445}" \
            -e "ENABLE_HYSTERIA2=${enable_hysteria2:-true}" \
            -e "ENABLE_WIREGUARD=${enable_wireguard:-true}" \
            -e "ENABLE_AMNEZIAWG=${enable_amneziawg:-true}" \
            -e "ENABLE_DNSTT=${enable_dnstt:-false}" \
            -e "ENABLE_SLIPSTREAM=${enable_slipstream:-false}" \
            -e "SLIPSTREAM_SUBDOMAIN=${slipstream_subdomain:-s}" \
            -e "ENABLE_MASTERDNS=${enable_masterdns:-true}" \
            -e "MASTERDNS_SUBDOMAIN=${masterdns_subdomain:-m}" \
            -e "MASTERDNS_PUBLIC_SUBDOMAIN=${masterdns_public_subdomain:-}" \
            -e "ENABLE_GOOSERELAY=${enable_gooserelay:-false}" \
            -e "PORT_GOOSE=${port_goose:-8444}" \
            -e "ENABLE_TRUSTTUNNEL=${enable_trusttunnel:-true}" \
            -e "ENABLE_XHTTP=${enable_xhttp:-true}" \
            -e "PORT_XHTTP=${port_xhttp:-2096}" \
            -e "XHTTP_REALITY_TARGET=${xhttp_reality_target:-dl.google.com:443}" \
            -e "ENABLE_TELEMT=${enable_telemt:-true}" \
            -e "TELEMT_TLS_DOMAIN=${telemt_tls_domain:-dl.google.com}" \
            -e "TELEMT_MAX_TCP_CONNS=${telemt_max_tcp_conns:-100}" \
            -e "TELEMT_MAX_UNIQUE_IPS=${telemt_max_unique_ips:-10}" \
            -e "PORT_TELEMT=${port_telemt:-993}" \
            -e "ENABLE_SS=${enable_ss:-false}" \
            -e "PORT_SS=${port_ss:-8388}" \
            -e "SS_METHOD=${ss_method:-2022-blake3-aes-128-gcm}" \
            -e "DNSTT_SUBDOMAIN=${dnstt_subdomain:-t}" \
            -e "ENABLE_XDNS=${enable_xdns:-false}" \
            -e "XDNS_SUBDOMAIN=${xdns_subdomain:-x}" \
            -e "XDNS_MTU=${xdns_mtu:-35}" \
            -e "XDNS_RESOLVERS=${xdns_resolvers:-1.1.1.1,8.8.8.8}" \
            -e "PORT_DNS=${port_dns:-53}" \
            -e "PORT_XDNS=${port_xdns:-53}" \
        --entrypoint /bin/bash \
        bootstrap -c 'source /app/lib/common.sh; source /app/lib/sing-box.sh; source /app/lib/xray.sh; source /app/lib/sync.sh; source /app/lib/provision.sh; provision_all_users force'; then
        user_count=$(echo "$users_found" | wc -w | tr -d ' ')
        echo -e "  ${GREEN}✓${NC} provisioning run finished"
    else
        echo -e "  ${RED}✗${NC} provisioning run failed"
        warn "    See the output above for the failing user(s)"
    fi

    echo ""

    # The reconcile happened inside the run above (provision_all_users does
    # bundles THEN sync_server_users, always reaching the reconcile even if a
    # bundle failed). Reload the proxies so the re-inserted users take effect.
    docker compose restart sing-box xray >/dev/null 2>&1 || true
    echo ""

    if [[ $user_count -gt 0 ]]; then
        success "Regenerated $user_count user bundle(s)"
        echo ""
        echo -e "${CYAN}Bundles location:${NC} outputs/bundles/"
        echo ""
        echo -e "${CYAN}Next steps:${NC}"
        echo "  1. Distribute new configs to users"
        echo "  2. Or create zip packages: moav user package <username>"
        echo ""
        echo -e "${YELLOW}Note:${NC} Users can also manually update the IP in their client app"
        echo "      since credentials haven't changed."
    else
        warn "No bundles were regenerated."
    fi
}

# =============================================================================
# Conduit lifetime-offset auto-updater (systemd watcher)
# =============================================================================
# conduit_bytes_* gauges reset on every Conduit restart; update-conduit-offsets.sh
# banks the ended session into a persistent offset so the *_lifetime totals
# survive restarts — but only if run promptly after each restart. This installs a
# systemd service (scripts/conduit-offsets-watch.sh) that reacts to Conduit
# `start` events and runs the updater automatically.

CONDUIT_OFFSETS_UNIT="moav-conduit-offsets.service"
CONDUIT_OFFSETS_UNIT_PATH="/etc/systemd/system/${CONDUIT_OFFSETS_UNIT}"

# Is systemd actually the init system here? (false in many containers / WSL)
_has_systemd() {
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
}

# Prefix for privileged writes (empty when already root).
_root_prefix() {
    if [[ $EUID -eq 0 ]]; then
        echo ""
    elif command -v sudo >/dev/null 2>&1; then
        echo "sudo"
    else
        echo ""  # caller will fail loudly on the privileged op
    fi
}

conduit_offsets_install() {
    local quiet="${1:-}"
    if ! _has_systemd; then
        [[ "$quiet" == "--quiet" ]] && return 0
        error "systemd not detected — cannot install the auto-updater service."
        echo "  Run scripts/update-conduit-offsets.sh manually after each Conduit restart,"
        echo "  or add it to cron. (This host isn't running systemd as init.)"
        return 1
    fi

    local sudo_prefix; sudo_prefix=$(_root_prefix)
    if [[ $EUID -ne 0 && -z "$sudo_prefix" ]]; then
        error "Need root (or sudo) to install ${CONDUIT_OFFSETS_UNIT}."
        return 1
    fi

    # Write the unit, pinned to this install's absolute path.
    $sudo_prefix tee "$CONDUIT_OFFSETS_UNIT_PATH" >/dev/null <<UNIT
[Unit]
Description=MoaV Conduit lifetime bandwidth offset auto-updater
Documentation=https://github.com/MotherofallVPNs/moav
After=docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=${SCRIPT_DIR}
ExecStart=/bin/bash ${SCRIPT_DIR}/scripts/conduit-offsets-watch.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

    $sudo_prefix systemctl daemon-reload
    if $sudo_prefix systemctl enable --now "$CONDUIT_OFFSETS_UNIT" >/dev/null 2>&1; then
        [[ "$quiet" == "--quiet" ]] || success "Installed and started ${CONDUIT_OFFSETS_UNIT}"
        [[ "$quiet" == "--quiet" ]] && info "Conduit lifetime offsets will now auto-update on each restart (${CONDUIT_OFFSETS_UNIT})"
        return 0
    else
        error "Failed to enable ${CONDUIT_OFFSETS_UNIT}. Check: systemctl status ${CONDUIT_OFFSETS_UNIT}"
        return 1
    fi
}

conduit_offsets_uninstall() {
    if ! _has_systemd; then
        warn "systemd not detected — nothing to uninstall."
        return 0
    fi
    local sudo_prefix; sudo_prefix=$(_root_prefix)
    $sudo_prefix systemctl disable --now "$CONDUIT_OFFSETS_UNIT" >/dev/null 2>&1 || true
    $sudo_prefix rm -f "$CONDUIT_OFFSETS_UNIT_PATH"
    $sudo_prefix systemctl daemon-reload
    success "Removed ${CONDUIT_OFFSETS_UNIT} (offsets are no longer auto-updated; run scripts/update-conduit-offsets.sh manually if needed)"
}

conduit_offsets_status() {
    if ! _has_systemd; then
        info "systemd not detected on this host."
        return 0
    fi
    if [[ -f "$CONDUIT_OFFSETS_UNIT_PATH" ]]; then
        systemctl status "$CONDUIT_OFFSETS_UNIT" --no-pager 2>/dev/null || true
    else
        info "${CONDUIT_OFFSETS_UNIT} is not installed. Install with: moav conduit-offsets install"
    fi
}

cmd_conduit_offsets() {
    case "${1:-status}" in
        install)   conduit_offsets_install ;;
        uninstall|remove) conduit_offsets_uninstall ;;
        status)    conduit_offsets_status ;;
        *)
            echo "Usage: moav conduit-offsets {install|uninstall|status}"
            echo ""
            echo "  install    Install a systemd watcher that re-banks Conduit lifetime"
            echo "             offsets automatically on every Conduit restart."
            echo "  uninstall  Remove the watcher (back to manual updates)."
            echo "  status     Show the watcher service status."
            return 1
            ;;
    esac
}

# Called at the end of `moav start`: auto-install the watcher the first time
# Conduit + monitoring are both running, so lifetime offsets stay accurate
# without the operator remembering to run the script. No-op if already
# installed, opted out (CONDUIT_OFFSETS_AUTOUPDATE=false), or no systemd.
auto_setup_conduit_offsets() {
    [[ "$(get_env_val "CONDUIT_OFFSETS_AUTOUPDATE" "$SCRIPT_DIR/.env" "true")" == "true" ]] || return 0
    _has_systemd || return 0
    [[ -f "$CONDUIT_OFFSETS_UNIT_PATH" ]] && return 0
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^moav-conduit$'    || return 0
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^moav-prometheus$' || return 0
    echo ""
    info "Conduit + monitoring detected — installing the lifetime-offset auto-updater..."
    conduit_offsets_install --quiet || \
        warn "Auto-install failed; run 'moav conduit-offsets install' manually (or set CONDUIT_OFFSETS_AUTOUPDATE=false to silence)."
}


# =============================================================================
# Entry Point
# =============================================================================

main_interactive() {
    # Start async update check (won't block, results cached for next header display)
    check_for_updates

    # Check prerequisites only if not already verified
    # Also re-check if .env is missing (user may have deleted it)
    if ! prereqs_already_checked; then
        print_header
        # Clear stale prereqs flag if .env is missing
        if [[ -f "$PREREQS_FILE" ]] && [[ ! -f ".env" ]]; then
            rm -f "$PREREQS_FILE"
        fi
        echo -e "${DIM}First run - checking prerequisites...${NC}"
        echo ""
        check_prerequisites
        echo ""
        sleep 1
    fi

    # Check if bootstrap needed
    if ! check_bootstrap; then
        warn "Bootstrap has not been run yet!"
        echo ""
        info "Bootstrap is required for first-time setup."
        echo "  It generates keys, obtains TLS certificates, and creates users."
        echo ""

        if confirm "Run bootstrap now?" "y"; then
            run_bootstrap || exit 1
            press_enter
        else
            warn "You can run bootstrap later from the main menu"
            warn "or manually with: docker compose --profile setup run --rm bootstrap"
            press_enter
        fi
    fi

    # Show main menu
    main_menu
}

main() {
    local cmd="${1:-}"

    case "$cmd" in
        "")
            main_interactive
            ;;
        help|--help|-h)
            show_usage
            ;;
        version|--version|-v)
            show_versions
            ;;
        install)
            do_install
            ;;
        uninstall)
            shift
            do_uninstall "$@"
            ;;
        update)
            shift
            cmd_update "$@"
            ;;
        _post-update)
            # Internal: re-exec target after self-update pulls new code.
            # $2 = short commit before the pull (for config-template diffing).
            check_component_versions
            check_source_rebuilds "${2:-}"
            migrate_dns_tunnel_state
            check_env_additions
            check_config_template_changes "${2:-}"
            print_post_update_apply_steps
            ;;
        check)
            cmd_check
            ;;
        doctor)
            shift
            cmd_doctor "$@"
            ;;
        bootstrap)
            cmd_bootstrap "$@"
            ;;
        domainless|domain-less|no-domain)
            cmd_domainless
            ;;
        admin)
            shift
            cmd_admin "$@"
            ;;
        profiles)
            cmd_profiles
            ;;
        start)
            shift
            cmd_start "$@"
            ;;
        stop)
            shift
            cmd_stop "$@"
            ;;
        restart)
            shift
            cmd_restart "$@"
            ;;
        status)
            cmd_status
            ;;
        logs)
            shift
            cmd_logs "$@"
            ;;
        users)
            cmd_users
            ;;
        user)
            shift
            cmd_user "$@"
            ;;
        build)
            shift
            cmd_build "$@"
            ;;
        test)
            shift
            cmd_test "$@"
            ;;
        client)
            shift
            cmd_client "$@"
            ;;
        export)
            shift
            cmd_export "$@"
            ;;
        import)
            shift
            cmd_import "$@"
            ;;
        migrate-ip|migrate_ip|migrateip)
            shift
            cmd_migrate_ip "$@"
            ;;
        regenerate-users|regenerate_users|regen-users)
            cmd_regenerate_users
            ;;
        net|net-tuning|sysctl)
            shift
            cmd_net "$@"
            ;;
        conduit-offsets|conduit_offsets|conduit-lifetime)
            shift
            cmd_conduit_offsets "$@"
            ;;
        cert|certs|certificate)
            shift
            cmd_cert "$@"
            ;;
        setup-dns|setup_dns|dns-setup)
            cmd_setup_dns
            ;;
        switch-dns|switch_dns|dns-switch|dnsswitch)
            shift
            cmd_switch_dns "$@"
            ;;
        donate)
            shift
            cmd_donate "$@"
            ;;
        conduit)
            shift
            cmd_conduit "$@"
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Run main
main "$@"
