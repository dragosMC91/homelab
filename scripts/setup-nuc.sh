#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Intel NUC 8 Pro (i3-8145U, 16GB) Setup Script
#
# Prepares a fresh Ubuntu Server 24.04 LTS install on the NUC:
# sets hostname, installs VA-API drivers for Jellyfin HW transcoding
# (Intel Quick Sync on 8th gen Coffee Lake), installs Docker, and
# creates the shared Docker network.
#
# Services on this node: Jellyfin, Uptime Kuma, Tailscale
# Hostname: nuc
#
# Usage:
#   ./scripts/setup-nuc.sh --hostname nuc
# ------------------------------------------------------------------

HOSTNAME=""
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    echo "Usage: $0 --hostname <name>"
    echo ""
    echo "  --hostname    Hostname for this NUC (e.g. nuc)"
    echo ""
    echo "Examples:"
    echo "  $0 --hostname nuc"
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

if [[ "$(uname -m)" != "x86_64" ]]; then
    echo "Warning: This script is intended for x86_64 (Intel NUC)."
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
# 3. Install Intel VA-API drivers (Jellyfin HW transcoding)
# ------------------------------------------------------------------

log "Installing Intel microcode and VA-API drivers"
apt-get install -y intel-microcode intel-media-va-driver-non-free vainfo

if [[ -e /dev/dri/renderD128 ]]; then
    echo "GPU render node /dev/dri/renderD128 is present."
    echo "VA-API profiles (run 'vainfo' after reboot to verify full list):"
    vainfo 2>&1 | grep -E "VAProfile|vainfo" || true
else
    echo "Warning: /dev/dri/renderD128 not found."
    echo "A reboot may be required for the Intel GPU driver to load."
    echo "After reboot, verify with: ls /dev/dri && vainfo"
fi

# ------------------------------------------------------------------
# 4. Install Docker
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
# 5. Create Docker network and seed .env files
# ------------------------------------------------------------------

log "Running 'make setup' to create network and seed .env files"
make -C "$REPO_DIR" setup

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------

log "Setup complete for '$HOSTNAME'"
echo "Next steps:"
echo "  1. Log out and back in (so docker group takes effect), or run: newgrp docker"
echo "  2. Set a static IP for this NUC via your router's DHCP reservation"
echo "  3. Verify VA-API:  vainfo"
echo "  4. Review .env files in services/ and adjust as needed"
echo "  5. Start services:"
echo "       cd $REPO_DIR"
echo "       make up-tailscale"
echo "       make up-uptime-kuma"
echo "       make up-jellyfin       # (once Jellyfin service is added)"
echo ""
