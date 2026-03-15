#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Raspberry Pi 3B+ Setup Script
#
# Prepares a fresh Raspberry Pi OS Lite (64-bit) install for the
# homelab: sets hostname, configures swap, installs Docker, frees
# port 53 for AdGuard Home, and creates the shared Docker network.
#
# Services on this node: AdGuard Home, Tailscale
# Hostname: pi-infra
#
# For Intel NUC nodes, use setup-nuc.sh instead.
# For Raspberry Pi 5 (NAS), a separate setup script is needed.
#
# Usage:
#   ./scripts/setup-pi.sh --hostname pi-infra
# ------------------------------------------------------------------

HOSTNAME=""
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    echo "Usage: $0 --hostname <name>"
    echo ""
    echo "  --hostname    Role-based hostname for this Pi (e.g. pi-infra)"
    echo ""
    echo "Examples:"
    echo "  $0 --hostname pi-infra    # Infrastructure Pi (AdGuard + Tailscale)"
    echo ""
    echo "For Intel NUC nodes, use setup-nuc.sh instead."
    exit 1
}

log() {
    echo ""
    echo "==> $1"
    echo ""
}

# ------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname)
            HOSTNAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

if [[ -z "$HOSTNAME" ]]; then
    echo "Error: --hostname is required."
    echo ""
    usage
fi

# ------------------------------------------------------------------
# Preflight checks
# ------------------------------------------------------------------

if [[ "$(uname -m)" != "aarch64" ]]; then
    echo "Warning: This script is intended for 64-bit Raspberry Pi OS (aarch64)."
    echo "Detected architecture: $(uname -m)"
    read -rp "Continue anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "This script requires root privileges. Re-running with sudo..."
    exec sudo bash "$0" --hostname "$HOSTNAME"
fi

REAL_USER="${SUDO_USER:-$USER}"

# ------------------------------------------------------------------
# 1. Set hostname
# ------------------------------------------------------------------

log "Setting hostname to '$HOSTNAME'"
hostnamectl set-hostname "$HOSTNAME"
sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$HOSTNAME/" /etc/hosts 2>/dev/null || true
echo "Hostname set to: $(hostname)"

# ------------------------------------------------------------------
# 2. System update
# ------------------------------------------------------------------

log "Updating system packages"
apt-get update -y
apt-get upgrade -y

# ------------------------------------------------------------------
# 3. Install Docker
# ------------------------------------------------------------------

if command -v docker &>/dev/null; then
    echo "Docker is already installed: $(docker --version)"
else
    log "Installing Docker via official convenience script"
    curl -fsSL https://get.docker.com | bash
fi

log "Adding '$REAL_USER' to the docker group"
usermod -aG docker "$REAL_USER"

if ! docker compose version &>/dev/null; then
    log "Installing docker-compose-plugin"
    apt-get install -y docker-compose-plugin
else
    echo "docker compose plugin already installed: $(docker compose version)"
fi

# ------------------------------------------------------------------
# 4. Configure swap (1GB RAM needs swap as a safety net)
# ------------------------------------------------------------------

SWAP_SIZE_MB=2048

if swapon --show | grep -q "/swapfile"; then
    echo "Swap is already configured:"
    swapon --show
else
    log "Configuring ${SWAP_SIZE_MB}MB swap"
    if [[ -f /swapfile ]]; then
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
    fi
    dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE_MB" status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    echo "Swap configured: ${SWAP_SIZE_MB}MB"
fi

# Lower swappiness so swap is only used under pressure
sysctl vm.swappiness=10
grep -q "vm.swappiness" /etc/sysctl.conf 2>/dev/null \
    && sed -i 's/vm.swappiness=.*/vm.swappiness=10/' /etc/sysctl.conf \
    || echo "vm.swappiness=10" >> /etc/sysctl.conf

# ------------------------------------------------------------------
# 5. Free port 53 for AdGuard Home
#
# Raspberry Pi OS Lite typically does NOT run systemd-resolved,
# but we check and disable it just in case.
# ------------------------------------------------------------------

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    log "Disabling systemd-resolved to free port 53 for AdGuard Home"
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved

    RESOLV_OK=true
    grep -q "nameserver 1.1.1.1" /etc/resolv.conf 2>/dev/null || RESOLV_OK=false
    grep -q "nameserver 8.8.8.8" /etc/resolv.conf 2>/dev/null || RESOLV_OK=false

    if [[ "$RESOLV_OK" == "false" ]]; then
        if [[ -L /etc/resolv.conf ]]; then
            rm /etc/resolv.conf
        fi
        printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
        echo "resolv.conf written with Cloudflare + Google DNS fallback."
    else
        echo "resolv.conf already has correct nameservers -- skipping."
    fi
else
    echo "systemd-resolved is not active -- port 53 is already free."
fi

# ------------------------------------------------------------------
# 6. Create Docker network and seed .env files
# ------------------------------------------------------------------

log "Running 'make setup' to create network and seed .env files"
make -C "$REPO_DIR" setup

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------

log "Setup complete for '$HOSTNAME'"
echo "Next steps:"
echo "  1. Log out and back in (so docker group takes effect), or run: newgrp docker"
echo "  2. Set a static IP via your router's DHCP reservation"
echo "  3. Review .env files in services/ and adjust as needed"
echo "  4. Start services:"
echo "       cd $REPO_DIR"
echo "       make up-tailscale"
echo "       make up-adguard-home"
echo "  5. Set this Pi's IP as the DNS server in your router's DHCP settings"
echo ""
