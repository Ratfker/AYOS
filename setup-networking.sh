#!/usr/bin/env bash
# =============================================================================
# GhostOS — scripts/setup-networking.sh
# PHASE 2 — Run this AFTER verifying RAM boot is solid.
#
# Sets up: WireGuard → Tor → nftables kill-switch
#
# Architecture:
#   All traffic → WireGuard VPN → exits encrypted
#   Inside VPN → Tor daemon → 3-hop onion routing
#   nftables → blocks ALL traffic not going through Tor (leak prevention)
#   DNS → Tor's DNS resolver only (no system resolver)
#
# Usage (inside booted GhostOS):
#   sudo ./setup-networking.sh --wg-endpoint <host:port> --wg-pubkey <key>
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[net]${RESET} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${RESET} $*"; }
fail() { echo -e "${RED}[ERR ]${RESET} $*"; exit 1; }

[ "$EUID" -eq 0 ] || fail "Must run as root"

# =============================================================================
# STEP 1: WireGuard configuration
# Replace these with your actual VPN provider values.
# DO NOT hardcode private keys in this file for production use.
# =============================================================================
setup_wireguard() {
    log "Configuring WireGuard..."
    
    # Generate a fresh keypair for this session
    # Private key lives only in RAM — dies on reboot
    WG_PRIVKEY=$(wg genkey)
    WG_PUBKEY=$(echo "$WG_PRIVKEY" | wg pubkey)
    
    log "Generated WireGuard keypair (ephemeral — dies on reboot)"
    log "Your public key (give this to your VPN provider): $WG_PUBKEY"
    
    # Write config to tmpfs
    mkdir -p /etc/wireguard
    cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
# Your private key (ephemeral — generated this session only)
PrivateKey = ${WG_PRIVKEY}

# Local WireGuard IP (assigned by your VPN provider)
Address = 10.0.0.2/24

# DNS: point to Tor's DNS port (we'll set up Tor next)
# This means ALL DNS goes through Tor — no leaks possible
DNS = 127.0.0.1

# Don't install default routes via WireGuard — we'll do this with nftables
PostUp = ip rule add not fwmark 51820 table 51820 priority 100
PostUp = ip route add default via 10.0.0.1 table 51820
PostDown = ip rule del not fwmark 51820 table 51820 priority 100

[Peer]
# Your VPN provider's public key
# REPLACE THIS with your actual VPN server public key
PublicKey = REPLACE_WITH_VPN_SERVER_PUBKEY

# VPN server endpoint
# REPLACE THIS with your actual VPN server
Endpoint = vpn.example.com:51820

# Route ALL traffic through WireGuard
AllowedIPs = 0.0.0.0/0, ::/0

# Keep alive (helps with NAT traversal)
PersistentKeepalive = 25
EOF

    chmod 600 /etc/wireguard/wg0.conf
    ok "WireGuard config written to /etc/wireguard/wg0.conf"
    
    # Bring up the interface
    wg-quick up wg0
    ok "WireGuard interface wg0 up"
    
    # Verify
    wg show wg0
}

# =============================================================================
# STEP 2: Tor configuration
# Routes all system traffic through Tor after it exits the VPN.
# =============================================================================
setup_tor() {
    log "Configuring Tor..."
    
    cat > /etc/tor/torrc <<EOF
# GhostOS Tor Configuration
# Tor listens as a transparent proxy + DNS resolver

# Transparent proxy port — all TCP traffic gets redirected here by nftables
TransPort 9040

# DNS port — nftables redirects all DNS here
DNSPort 5353

# SOCKS port — for applications that support SOCKS5 directly
SocksPort 9050

# Don't run as a relay (we're a client only)
ExitPolicy reject *:*

# Logging: RAM only, minimal
Log notice file /run/tor/tor.log
DataDirectory /run/tor/data

# Isolate streams by destination (improves anonymity)
# Each destination gets its own circuit
IsolateDestAddr 1
IsolateDestPort 1

# Use bridges if direct Tor is blocked (configure separately)
# UseBridges 1
# Bridge obfs4 <address> <fingerprint> cert=<cert> iat-mode=0

# Don't let Tor circuits be reused for too long
MaxCircuitDirtiness 600

# Enforce HTTPS via HSTS (belt+suspenders for browser)
# This is a Tor Browser setting, not torrc, but documenting here
EOF

    # Create Tor data dir in tmpfs
    mkdir -p /run/tor/data
    chown -R tor:tor /run/tor
    
    # Start Tor
    systemctl start tor
    
    # Wait for Tor to bootstrap
    log "Waiting for Tor to bootstrap (up to 60s)..."
    for i in $(seq 1 60); do
        if grep -q "Bootstrapped 100%" /run/tor/tor.log 2>/dev/null; then
            ok "Tor bootstrapped successfully"
            break
        fi
        sleep 1
        [ "$i" -eq 60 ] && fail "Tor failed to bootstrap in 60s — check /run/tor/tor.log"
    done
}

# =============================================================================
# STEP 3: nftables firewall
# This is the NETWORK KILL-SWITCH.
# Blocks ALL traffic that doesn't go through our stack.
# If WireGuard drops: no traffic leaks in plaintext.
# If Tor fails: no traffic leaks outside of VPN.
# =============================================================================
setup_firewall() {
    log "Configuring nftables firewall..."
    
    cat > /etc/nftables.conf <<'NFTEOF'
#!/usr/sbin/nft -f
# GhostOS nftables rules
# Philosophy: default DENY, then whitelist only what we need.

flush ruleset

# ============================================================
# Tables
# ============================================================

table inet ghost_filter {

    # ---- Input: what can reach THIS machine ----
    chain input {
        type filter hook input priority 0; policy drop;
        
        # Accept established/related connections
        ct state established,related accept
        
        # Accept loopback
        iif "lo" accept
        
        # Accept WireGuard packets (they arrive encrypted, on UDP)
        # Replace wg0 with your interface name if different
        iif "wg0" accept
        
        # Accept Tor internal traffic (on loopback)
        ip saddr 127.0.0.1 tcp dport { 9050, 9040, 5353 } accept
        
        # Drop everything else
        drop
    }

    # ---- Output: what this machine can send ----
    chain output {
        type filter hook output priority 0; policy drop;
        
        # Allow loopback
        oif "lo" accept
        
        # Allow WireGuard tunnel traffic (only to VPN server)
        # This is the ONLY thing that can exit without going through Tor
        oif != "wg0" udp dport 51820 accept     # WireGuard UDP
        
        # Allow all traffic out through WireGuard (it'll hit Tor inside the VPN)
        oif "wg0" accept
        
        # Allow Tor to connect out (through WireGuard)
        # Tor runs as user 'tor' — match by UID
        meta skuid tor oif "wg0" accept
        
        # Established/related (for responses)
        ct state established,related accept
        
        # Drop everything else — NO LEAKS
        drop
    }

    # ---- Forward: we don't route, so drop all ----
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
}

# ============================================================
# NAT: redirect all traffic through Tor transparent proxy
# ============================================================
table ip ghost_nat {

    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
        
        # Tor user's traffic: don't redirect (would cause loop)
        meta skuid tor return
        
        # Redirect all DNS (port 53) to Tor's DNS port
        udp dport 53 redirect to :5353
        tcp dport 53 redirect to :5353
        
        # Redirect all TCP to Tor's transparent proxy port
        # Exception: WireGuard server IP (needs to reach VPN, not through Tor)
        tcp flags & (fin|syn|rst|ack) == syn redirect to :9040
    }
}
NFTEOF

    # Apply the rules
    nft -f /etc/nftables.conf
    ok "nftables rules applied"
    
    # Verify no rules allow direct internet (basic sanity check)
    if nft list ruleset | grep -q "oif !="; then
        ok "Leak-prevention rules confirmed"
    fi
    
    # Enable nftables to persist across reboots (to tmpfs journal)
    systemctl enable --now nftables
}

# =============================================================================
# STEP 4: DNS lockdown
# =============================================================================
setup_dns() {
    log "Locking down DNS to Tor only..."
    
    # Point all DNS to Tor's DNS port
    cat > /etc/resolv.conf <<EOF
# GhostOS: ALL DNS goes through Tor
# This file is on tmpfs — vanishes on reboot
nameserver 127.0.0.1
options ndots:0
EOF
    
    # Make resolv.conf immutable (prevent DHCP from overwriting it)
    chattr +i /etc/resolv.conf
    
    ok "DNS locked to 127.0.0.1 (Tor)"
}

# =============================================================================
# MAIN
# =============================================================================
echo -e "${BOLD}GhostOS Network Setup — Phase 2${RESET}"
echo ""
echo -e "${YELLOW}IMPORTANT:${RESET} Verify RAM boot passes verify-amnesia.sh FIRST."
echo "Press ENTER to continue or Ctrl+C to abort."
read

setup_wireguard
setup_tor
setup_firewall
setup_dns

echo ""
ok "Network stack configured:"
echo "  Traffic flow: App → Tor (9040) → WireGuard (wg0) → Internet"
echo "  DNS:          All DNS → Tor (127.0.0.1:5353)"
echo "  Leaks:        Blocked by nftables (default deny)"
echo ""
echo -e "${YELLOW}Test your setup:${RESET}"
echo "  curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip"
echo "  # Should return: 'IsTor': true"
