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
# Raspberry Pi OS images flashed with Raspberry Pi Imager use cloud-init to
# set the hostname configured during flashing. cloud-init runs on every boot
# and will override manual hostname changes unless we tell it to stop.
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    echo "preserve_hostname: true" > /etc/cloud/cloud.cfg.d/99-homelab-hostname.cfg
    echo "cloud-init hostname preservation enabled."
fi

# Update /etc/hosts FIRST — changing the hostname before this breaks sudo
# because it tries to resolve the new hostname via /etc/hosts.
if grep -q "127\.0\.1\.1" /etc/hosts; then
    sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$HOSTNAME/" /etc/hosts
else
    echo "127.0.1.1	$HOSTNAME" >> /etc/hosts
fi
echo "$HOSTNAME" > /etc/hostname
hostnamectl set-hostname "$HOSTNAME"
hostname "$HOSTNAME"
echo "Hostname set to: $(hostname)"

# ------------------------------------------------------------------
# 2. System update
# ------------------------------------------------------------------

log "Updating system packages"
apt-get update -y
apt-get upgrade -y
apt-get install -y make

# ------------------------------------------------------------------
# 3. Install Zsh + Oh My Zsh
# ------------------------------------------------------------------

log "Installing Zsh"
sudo apt-get install -y zsh

if [[ -d "/home/$REAL_USER/.oh-my-zsh" ]]; then
    echo "Oh My Zsh is already installed for $REAL_USER -- skipping."
else
    log "Installing Oh My Zsh for '$REAL_USER'"
    sudo -u "$REAL_USER" sh -c \
        'RUNZSH=no CHSH=no sh -s -- --unattended' \
        < <(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)
fi

ZSH_CUSTOM="/home/$REAL_USER/.oh-my-zsh/custom"

# zsh-autosuggestions (colorize is built into Oh My Zsh)
if [[ -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]]; then
    echo "zsh-autosuggestions plugin already installed -- skipping."
else
    log "Installing zsh-autosuggestions plugin"
    sudo -u "$REAL_USER" git clone https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
fi

# Enable plugins in .zshrc
ZSHRC="/home/$REAL_USER/.zshrc"
if [[ -f "$ZSHRC" ]] && grep -q "^plugins=" "$ZSHRC"; then
    sed -i 's/^plugins=.*/plugins=(git colorize zsh-autosuggestions)/' "$ZSHRC"
    echo "Updated plugins in .zshrc"
fi

# Change default shell to zsh
if [[ "$(getent passwd "$REAL_USER" | cut -d: -f7)" != "$(command -v zsh)" ]]; then
    chsh -s "$(command -v zsh)" "$REAL_USER"
    echo "Default shell changed to zsh for $REAL_USER"
else
    echo "Default shell is already zsh for $REAL_USER"
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
# 5. Configure swap (1GB RAM needs swap as a safety net)
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
grep -q "vm.swappiness" /etc/sysctl.conf 2>/dev/null \
    && sed -i 's/vm.swappiness=.*/vm.swappiness=10/' /etc/sysctl.conf \
    || echo "vm.swappiness=10" >> /etc/sysctl.conf
sysctl -p

# ------------------------------------------------------------------
# 6. Free port 53 for AdGuard Home
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
# 7. Create Docker network and seed .env files
# ------------------------------------------------------------------

log "Running 'make setup' to create network and seed .env files"
make -C "$REPO_DIR" setup

# ------------------------------------------------------------------
# 8. Verify setup
# ------------------------------------------------------------------

log "Running post-setup verification"

VERIFY_PASS=0
VERIFY_FAIL=0

check() {
    local description="$1"
    shift
    if "$@" &>/dev/null; then
        echo "  [PASS] $description"
        ((VERIFY_PASS++))
    else
        echo "  [FAIL] $description"
        ((VERIFY_FAIL++))
    fi
}

# Hostname
check "Hostname is set to '$HOSTNAME'" \
    test "$(hostname)" = "$HOSTNAME"

check "Hostname in /etc/hosts" \
    grep -q "$HOSTNAME" /etc/hosts

check "cloud-init hostname preservation is set" \
    bash -c "[[ ! -d /etc/cloud/cloud.cfg.d ]] || grep -q 'preserve_hostname: true' /etc/cloud/cloud.cfg.d/99-homelab-hostname.cfg 2>/dev/null"

# Zsh
check "Zsh is installed" \
    command -v zsh

check "Oh My Zsh is installed for $REAL_USER" \
    test -d "/home/$REAL_USER/.oh-my-zsh"

check "zsh-autosuggestions plugin is installed" \
    test -d "/home/$REAL_USER/.oh-my-zsh/custom/plugins/zsh-autosuggestions"

check "Default shell for $REAL_USER is zsh" \
    bash -c "[[ \$(getent passwd '$REAL_USER' | cut -d: -f7) == */zsh ]]"

# Docker
check "Docker is installed" \
    command -v docker

check "Docker daemon is running" \
    docker info

check "Docker Compose plugin is installed" \
    docker compose version

check "User '$REAL_USER' is in docker group" \
    bash -c "getent group docker | grep -q '\b${REAL_USER}\b'"

# Swap
check "Swap is active on /swapfile" \
    bash -c "swapon --show | grep -q /swapfile"

ACTUAL_SWAP_MB=$(swapon --show=SIZE --bytes --noheadings 2>/dev/null | awk '{sum+=$1} END{printf "%d", sum/1024/1024}')
check "Swap size is >= ${SWAP_SIZE_MB}MB (actual: ${ACTUAL_SWAP_MB}MB)" \
    test "${ACTUAL_SWAP_MB:-0}" -ge "$SWAP_SIZE_MB"

check "vm.swappiness is 10" \
    test "$(sysctl -n vm.swappiness)" -eq 10

check "vm.swappiness persisted in /etc/sysctl.conf" \
    grep -q "vm.swappiness=10" /etc/sysctl.conf

check "Swap entry in /etc/fstab" \
    grep -q "/swapfile" /etc/fstab

# Port 53 / DNS
check "Port 53 is not in use (free for AdGuard)" \
    bash -c "! ss -tlnp | grep -q ':53 '"

check "systemd-resolved is not running" \
    bash -c "! systemctl is-active --quiet systemd-resolved 2>/dev/null"

check "/etc/resolv.conf has a nameserver entry" \
    grep -q "^nameserver" /etc/resolv.conf

check "DNS resolution works" \
    bash -c "getent hosts google.com >/dev/null 2>&1 || host google.com >/dev/null 2>&1"

# Docker network
check "Docker network 'homelab' exists" \
    docker network inspect homelab

# Summary
echo ""
echo "  ────────────────────────────────"
echo "  Results: $VERIFY_PASS passed, $VERIFY_FAIL failed"
echo "  ────────────────────────────────"

if [[ $VERIFY_FAIL -gt 0 ]]; then
    echo ""
    echo "  Some checks failed. Review the [FAIL] items above."
    echo "  You can re-run this script safely — all steps are idempotent."
fi

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
