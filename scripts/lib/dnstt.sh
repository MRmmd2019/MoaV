#!/bin/bash
# dnstt DNS tunnel configuration functions

DNSTT_CONFIG_DIR="/configs/dnstt"

ensure_dnstt_key_permissions() {
    local key_file="$STATE_DIR/keys/dnstt-server.key.hex"
    local pub_file="$STATE_DIR/keys/dnstt-server.pub.hex"

    if [[ -f "$key_file" ]]; then
        if ! chown 100:101 "$key_file" 2>/dev/null; then
            log_error "Failed to set dnstt private key ownership for container user 100:101"
            return 1
        fi
        if ! chmod 0600 "$key_file" 2>/dev/null; then
            log_error "Failed to lock down dnstt private key permissions"
            return 1
        fi
    fi

    if [[ -f "$pub_file" ]]; then
        chown 100:101 "$pub_file" 2>/dev/null || true
        chmod 0644 "$pub_file" 2>/dev/null || true
    fi
}

generate_dnstt_config() {
    log_info "Setting up dnstt configuration..."

    ensure_dir "$DNSTT_CONFIG_DIR"
    ensure_dir "$STATE_DIR/keys"

    # Generate keypair if not exists or is empty/invalid
    local need_keygen=false
    local key_file="$STATE_DIR/keys/dnstt-server.key.hex"

    if [[ ! -f "$key_file" ]]; then
        log_info "dnstt key file does not exist, will generate..."
        need_keygen=true
    elif [[ ! -s "$key_file" ]]; then
        log_info "dnstt key file is empty, regenerating..."
        need_keygen=true
    else
        local key_size=$(wc -c < "$key_file" | tr -d ' ')
        if [[ $key_size -lt 60 ]]; then
            log_info "dnstt key file too small ($key_size bytes), regenerating..."
            need_keygen=true
        else
            log_info "dnstt key file exists and looks valid ($key_size bytes)"
        fi
    fi

    if [[ "$need_keygen" == "true" ]]; then
        log_info "Generating dnstt x25519 keypair..."

        # Generate x25519 keypair using openssl
        if ! openssl genpkey -algorithm x25519 -out "$STATE_DIR/keys/dnstt-temp.pem" 2>&1; then
            log_error "Failed to generate x25519 key with openssl"
            return 1
        fi

        if [[ ! -f "$STATE_DIR/keys/dnstt-temp.pem" ]]; then
            log_error "x25519 key file was not created"
            return 1
        fi

        # Extract raw private key (last 32 bytes of DER) as hex
        log_info "Extracting private key to $STATE_DIR/keys/dnstt-server.key.hex"
        openssl pkey -in "$STATE_DIR/keys/dnstt-temp.pem" -outform DER 2>/dev/null | tail -c 32 | od -An -tx1 | tr -d ' \n' > "$STATE_DIR/keys/dnstt-server.key.hex"

        # Verify private key was written
        if [[ ! -f "$STATE_DIR/keys/dnstt-server.key.hex" ]]; then
            log_error "Private key file was not created!"
            log_error "Directory contents:"
            ls -la "$STATE_DIR/keys/" || true
            return 1
        fi

        local privkey_size=$(wc -c < "$STATE_DIR/keys/dnstt-server.key.hex" | tr -d ' ')
        log_info "Private key file size: $privkey_size bytes"

        # Extract raw public key (last 32 bytes of DER pubkey) as hex
        log_info "Extracting public key to $STATE_DIR/keys/dnstt-server.pub.hex"
        openssl pkey -in "$STATE_DIR/keys/dnstt-temp.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | od -An -tx1 | tr -d ' \n' > "$STATE_DIR/keys/dnstt-server.pub.hex"

        rm -f "$STATE_DIR/keys/dnstt-temp.pem"

        # Verify keys were created and have content
        log_info "Verifying key files..."
        ls -la "$STATE_DIR/keys/"

        if [[ ! -s "$STATE_DIR/keys/dnstt-server.key.hex" ]]; then
            log_error "Failed to generate dnstt private key - file is empty or missing"
            return 1
        fi
        if [[ ! -s "$STATE_DIR/keys/dnstt-server.pub.hex" ]]; then
            log_error "Failed to generate dnstt public key - file is empty or missing"
            return 1
        fi

        log_info "dnstt keypair generated successfully"
        log_info "Private key at: $STATE_DIR/keys/dnstt-server.key.hex ($(wc -c < "$STATE_DIR/keys/dnstt-server.key.hex" | tr -d ' ') bytes)"
        log_info "Public key at: $STATE_DIR/keys/dnstt-server.pub.hex ($(wc -c < "$STATE_DIR/keys/dnstt-server.pub.hex" | tr -d ' ') bytes)"
    fi

    if ! ensure_dnstt_key_permissions; then
        return 1
    fi

    local dnstt_pubkey
    dnstt_pubkey=$(cat "$STATE_DIR/keys/dnstt-server.pub.hex")

    # Write server config
    # Upstream points to sing-box's mixed inbound (SOCKS5/HTTP proxy)
    cat > "$DNSTT_CONFIG_DIR/server.conf" <<EOF
# dnstt server configuration
DNSTT_DOMAIN=${DNSTT_SUBDOMAIN:-t}.${DOMAIN}
DNSTT_PRIVKEY_FILE=/state/keys/dnstt-server.key.hex
DNSTT_UPSTREAM=sing-box:1080
EOF

    # Write public key for clients
    echo "$dnstt_pubkey" > "$DNSTT_CONFIG_DIR/server.pub"

    # Copy to outputs for easy distribution
    ensure_dir "/outputs/dnstt"
    cp "$DNSTT_CONFIG_DIR/server.pub" "/outputs/dnstt/server.pub"

    log_info "dnstt configuration created"
    log_info "Public key (hex): $dnstt_pubkey"
}

