#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# Raspberry Pi 5 NAS Setup Script
#
# Prepares a fresh Raspberry Pi OS Lite (64-bit) install on a Pi 5
# with a Penta SATA HAT for use as a NAS node: sets hostname,
# installs Docker and Samba, creates per-user NAS shares with
# private folders, and prepares the system for FileBrowser and
# Tailscale (which run as Docker containers).
#
# PREREQUISITES — Hardware & Boot Setup
# ======================================
#
# This script assumes you have already completed the one-time hardware
# and boot preparation below. These steps are manual because they
# involve reboots and interactive disk identification.
#
# 1. Attach the Penta SATA HAT (see official Penta SATA HAT docs)
#
# 2. Enable PCIe in /boot/firmware/config.txt — add these lines:
#
#      dtparam=pciex1
#      dtparam=pciex1_gen=3
#
#    Save and reboot.
#
# 3. Partition an SSD for OS root + NAS storage
#
#    SD cards have limited write/read cycles, so we only use the SD
#    card to boot. The OS root is mounted on one of the SSDs attached
#    to the Penta SATA HAT. We can't boot directly from the SATA HAT
#    via PCIe, and using a USB-SATA enclosure adds latency and mess.
#
#    Identify your target SSD:
#
#      lsblk
#
#    Example output:
#
#      NAME        MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
#      sda           8:0    0   7.3T  0 disk
#      sdb           8:16   0 931.5G  0 disk
#      mmcblk0     179:0    0  29.7G  0 disk
#      ├─mmcblk0p1 179:1    0   512M  0 part /boot/firmware
#      └─mmcblk0p2 179:2    0  29.2G  0 part /
#
#    Wipe and partition the target SSD (e.g. /dev/sdb):
#
#      sudo wipefs -a /dev/sdb
#      sudo parted /dev/sdb mklabel gpt
#      sudo parted /dev/sdb mkpart root ext4 1MiB 100GiB
#      sudo parted /dev/sdb mkpart nas ext4 100GiB 100%
#
#    Format the partitions:
#
#      sudo mkfs.ext4 -L rootfs /dev/sdb1
#      sudo mkfs.ext4 -L nas-ssd /dev/sdb2
#
#    Verify:
#
#      lsblk -o NAME,SIZE,LABEL,FSTYPE
#
# 4. Copy root filesystem to SSD
#
#      sudo mkdir /mnt/ssd-root
#      sudo mount /dev/sdb1 /mnt/ssd-root
#      sudo rsync -axv / /mnt/ssd-root/
#
# 5. Update boot config to use SSD as root
#
#    Get the PARTUUID of the new root partition:
#
#      sudo blkid /dev/sdb1
#
#    Update /boot/firmware/cmdline.txt — replace the existing root=
#    parameter with root=PARTUUID=<your-sdb1-partuuid>
#
#    Update fstab ON THE SSD COPY (not the SD card):
#
#      sudo nano /mnt/ssd-root/etc/fstab
#
#    Set the root entry to:
#
#      PARTUUID=<your-sdb1-partuuid>  /  ext4  defaults,noatime  0  1
#
#    Keep the /boot/firmware line pointing to the SD card as-is.
#
# 6. Configure initramfs so SATA drivers load before root is mounted
#
#    initramfs is a small initial filesystem loaded during boot that
#    includes the necessary drivers. Without this, the Pi won't find
#    the pcie sata SSD at boot time.
#
#      sudo apt install initramfs-tools
#      sudo mkinitramfs -o /boot/firmware/initrd.img
#
#    Add to /boot/firmware/config.txt:
#
#      initramfs initrd.img followkernel
#
#    Add the SATA modules to initramfs:
#
#      # Check which modules the SATA HAT uses:
#      lsmod | grep -i -E 'ahci|ata|uas|pci'
#
#      will yield something like this
#       ahci                   65536  0
#       libahci                81920  1 ahci
#       libata                409600  2 libahci,ahci
#
#      # Add them:
#      echo -e "ahci\nlibahci\nlibata" | sudo tee -a /etc/initramfs-tools/modules
#
#      # Regenerate initramfs:
#      sudo mkinitramfs -o /boot/firmware/initrd.img
#
#    Reboot.
#
# 7. Verify the OS root is on the SSD
#
#      findmnt /
#      # Should show /dev/sdb1 (or your SSD partition)
#
# 8. (Optional) Add swap on the SSD
#
#      sudo fallocate -l 4G /swapfile
#      sudo chmod 600 /swapfile
#      sudo mkswap /swapfile
#      sudo swapon /swapfile
#      echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
#
#    This gives you: RAM -> zram (compressed) -> SSD swap as last
#    resort. SSDs handle swap writes without the wear concerns of
#    an SD card.
#
# 9. Set up LVM on the HDD for per-user storage
#
#    LVM is used to carve the HDDs into logical volumes — one per
#    family member plus a shared volume. They can be resized later
#    without reformatting.
#
#    Install LVM tools:
#
#      sudo apt-get install -y lvm2
#
#    Create a physical volume and volume group:
#
#      sudo pvcreate /dev/sda
#      sudo vgcreate nas-hdd /dev/sda
#
#    Create logical volumes (adjust names/sizes for your family):
#
#      sudo lvcreate -L 1T -n alice nas-hdd
#      sudo lvcreate -L 1T -n bob   nas-hdd
#      sudo lvcreate -L 2T -n shared nas-hdd
#      # Remaining space stays unallocated — expand later with:
#      #   sudo lvextend -L +500G /dev/nas-hdd/alice
#      #   sudo resize2fs /dev/nas-hdd/alice
#
#    Format them:
#
#      sudo mkfs.ext4 -L alice  /dev/nas-hdd/alice
#      sudo mkfs.ext4 -L bob    /dev/nas-hdd/bob
#      sudo mkfs.ext4 -L shared /dev/nas-hdd/shared
#
#    Create mount points and mount:
#
#      sudo mkdir -p /mnt/nas-hdd/{alice,bob,shared}
#      sudo mount /dev/nas-hdd/alice  /mnt/nas-hdd/alice
#      sudo mount /dev/nas-hdd/bob    /mnt/nas-hdd/bob
#      sudo mount /dev/nas-hdd/shared /mnt/nas-hdd/shared
#
#    Add to /etc/fstab for auto-mount on boot:
#
#      /dev/nas-hdd/alice  /mnt/nas-hdd/alice  ext4 defaults,noatime 0 2
#      /dev/nas-hdd/bob    /mnt/nas-hdd/bob    ext4 defaults,noatime 0 2
#      /dev/nas-hdd/shared /mnt/nas-hdd/shared ext4 defaults,noatime 0 2
#
# 10. Expected final state:
#
#      findmnt /              -> /dev/sdb1 (SSD root)
#      findmnt /boot/firmware -> /dev/mmcblk0p1 (SD card boot)
#      findmnt /mnt/nas-ssd   -> /dev/sdb2 (SSD NAS partition)
#      lsblk /dev/sda         -> LVM volumes (alice, bob, shared, ...)
#
# Services on this node: Docker (Tailscale + FileBrowser), Samba (native)
# Hostname: pi-nas
#
# Usage:
#   ./scripts/setup-pi-nas.sh --hostname pi-nas --nas-users alice,bob
# ------------------------------------------------------------------

HOSTNAME=""
NAS_USERS=()
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    echo "Usage: $0 --hostname <name> --nas-users <user1,user2,...>"
    echo ""
    echo "  --hostname    Role-based hostname for this Pi (e.g. pi-nas)"
    echo "  --nas-users   Comma-separated list of NAS user names (e.g. alice,bob)"
    echo ""
    echo "Examples:"
    echo "  $0 --hostname pi-nas --nas-users alice,bob"
    echo ""
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
        --nas-users)
            IFS=',' read -ra NAS_USERS <<< "$2"
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

if [[ ${#NAS_USERS[@]} -eq 0 ]]; then
    echo "Error: --nas-users is required (comma-separated list of NAS user names)."
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
    NAS_USERS_CSV=$(IFS=','; echo "${NAS_USERS[*]}")
    exec sudo bash "$0" --hostname "$HOSTNAME" --nas-users "$NAS_USERS_CSV"
fi

REAL_USER="${SUDO_USER:-$USER}"

# Verify the OS root is on SSD (not the SD card)
ROOT_DEV=$(findmnt -n -o SOURCE /)
if [[ "$ROOT_DEV" == /dev/mmcblk* ]]; then
    echo "Error: OS root is still on the SD card ($ROOT_DEV)."
    echo "Complete the hardware & boot preparation steps in the script header"
    echo "before running this script."
    exit 1
fi

# ------------------------------------------------------------------
# 1. Set hostname
# ------------------------------------------------------------------

log "Setting hostname to '$HOSTNAME'"

if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    echo "preserve_hostname: true" > /etc/cloud/cloud.cfg.d/99-homelab-hostname.cfg
    echo "cloud-init hostname preservation enabled."
fi

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
apt-get install -y zsh

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
# 5. Install and configure Samba
# ------------------------------------------------------------------

log "Installing Samba"
apt-get install -y samba samba-common-bin

SAMBA_CONF="/etc/samba/smb.conf"

# Harden Samba [global] settings:
#   - Encrypt all traffic (SMB3 encryption + signing mandatory)
#   - Block legacy protocols (SMBv1/v2)
#   - Restrict access to Tailscale network only (100.64.0.0/10 CGNAT range)
if ! grep -q "server smb encrypt" "$SAMBA_CONF" 2>/dev/null; then
    # Insert hardening directives into the existing [global] section
    # (appending a second [global] block works for most directives, but
    # hosts allow/deny must be in the main [global] to take effect reliably)
    sed -i '/^\[global\]/a\
   server smb encrypt = mandatory\
   server signing = mandatory\
   min protocol = SMB3_11\
   hosts allow = 100.64.0.0/10 127.0.0.1\
   hosts deny = 0.0.0.0/0' "$SAMBA_CONF"
    echo "Samba [global] hardening applied (SMB3-only, Tailscale-only)."
else
    echo "Samba [global] hardening already present -- skipping."
fi

# Create the nasusers group (used for shared folder access and FileBrowser)
if ! getent group nasusers &>/dev/null; then
    groupadd nasusers
fi

# Create NAS users and their private Samba shares
for nas_user in "${NAS_USERS[@]}"; do
    # Create Linux user (no SSH login, no home directory)
    if ! id "$nas_user" &>/dev/null; then
        adduser --no-create-home --shell /usr/sbin/nologin --disabled-password --gecos "" "$nas_user"
        echo "Created Linux user: $nas_user"
    else
        echo "Linux user '$nas_user' already exists -- skipping."
    fi
    usermod -aG nasusers "$nas_user"

    # Set ownership on the user's LVM mount point.
    # Group is set to 'nasusers' with 770 so FileBrowser (running as the
    # nasusers group) can access the directory without running as root.
    # Samba 'valid users' still restricts SMB access to only the owner.
    user_dir="/mnt/nas-hdd/$nas_user"
    if mountpoint -q "$user_dir"; then
        chown "$nas_user":nasusers "$user_dir"
        chmod 770 "$user_dir"
        echo "Set ownership on $user_dir"
    else
        echo "Warning: $user_dir is not mounted -- skipping ownership setup."
    fi

    # Add private Samba share for this user
    if ! grep -q "\[$nas_user\]" "$SAMBA_CONF" 2>/dev/null; then
        cat >> "$SAMBA_CONF" <<EOF

[$nas_user]
   path = /mnt/nas-hdd/$nas_user
   browseable = no
   read only = no
   create mask = 0770
   directory mask = 0770
   force group = nasusers
   valid users = $nas_user
EOF
        echo "Samba share [$nas_user] configured (private)."
    else
        echo "Samba share [$nas_user] already configured -- skipping."
    fi
done

# Set ownership on the shared LVM mount point
shared_dir="/mnt/nas-hdd/shared"
if mountpoint -q "$shared_dir"; then
    chown root:nasusers "$shared_dir"
    chmod 2775 "$shared_dir"
    echo "Set ownership on $shared_dir"
else
    echo "Warning: $shared_dir is not mounted -- skipping ownership setup."
fi

# Add shared Samba share
if ! grep -q "\[shared\]" "$SAMBA_CONF" 2>/dev/null; then
    # Build valid users list with spaces: "alice bob charlie"
    VALID_USERS=$(printf '%s ' "${NAS_USERS[@]}")
    cat >> "$SAMBA_CONF" <<EOF

[shared]
   path = /mnt/nas-hdd/shared
   browseable = no
   read only = no
   create mask = 0775
   directory mask = 0775
   valid users = $VALID_USERS
   force group = nasusers
EOF
    echo "Samba share [shared] configured."
else
    echo "Samba share [shared] already configured -- skipping."
fi

# Set ownership on the SSD NAS partition
if mountpoint -q /mnt/nas-ssd; then
    chown "$REAL_USER":"$REAL_USER" /mnt/nas-ssd
    chmod 2775 /mnt/nas-ssd
    echo "Set ownership on /mnt/nas-ssd"
else
    echo "Warning: /mnt/nas-ssd is not mounted -- skipping ownership setup."
fi

systemctl enable smbd
systemctl restart smbd
echo "Samba service enabled and started."

echo ""
echo "  NOTE: Set an initial Samba password for each user:"
for nas_user in "${NAS_USERS[@]}"; do
    echo "    sudo smbpasswd -a $nas_user"
done
echo ""

# ------------------------------------------------------------------
# 6. Create Docker network and seed .env files
# ------------------------------------------------------------------

log "Running 'make setup' to create network and seed .env files"
make -C "$REPO_DIR" setup

# ------------------------------------------------------------------
# 7. Verify setup
# ------------------------------------------------------------------

log "Running post-setup verification"

VERIFY_PASS=0
VERIFY_FAIL=0

check() {
    local description="$1"
    shift
    if "$@" &>/dev/null; then
        echo "  [PASS] $description"
        VERIFY_PASS=$((VERIFY_PASS + 1))
    else
        echo "  [FAIL] $description"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
    fi
}

# Hostname
check "Hostname is set to '$HOSTNAME'" \
    test "$(hostname)" = "$HOSTNAME"

check "Hostname in /etc/hosts" \
    grep -q "$HOSTNAME" /etc/hosts

check "cloud-init hostname preservation is set" \
    bash -c "[[ ! -d /etc/cloud/cloud.cfg.d ]] || grep -q 'preserve_hostname: true' /etc/cloud/cloud.cfg.d/99-homelab-hostname.cfg 2>/dev/null"

# OS root on SSD
check "OS root is on SSD (not SD card)" \
    bash -c "[[ \$(findmnt -n -o SOURCE /) != /dev/mmcblk* ]]"

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

# Samba
check "Samba is installed" \
    command -v smbd

check "Samba service is running" \
    systemctl is-active smbd

for nas_user in "${NAS_USERS[@]}"; do
    check "Linux user '$nas_user' exists" \
        id "$nas_user"

    check "Samba share [$nas_user] is configured" \
        grep -q "\[$nas_user\]" "$SAMBA_CONF"

    check "/mnt/nas-hdd/$nas_user is mounted" \
        mountpoint -q "/mnt/nas-hdd/$nas_user"
done

check "Samba share [shared] is configured" \
    grep -q "\[shared\]" "$SAMBA_CONF"

check "nasusers group exists" \
    getent group nasusers

# NAS mount points
check "/mnt/nas-ssd is mounted" \
    mountpoint -q /mnt/nas-ssd

check "/mnt/nas-hdd/shared is mounted" \
    mountpoint -q /mnt/nas-hdd/shared

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
    echo "  You can re-run this script safely -- all steps are idempotent."
fi

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------

log "Setup complete for '$HOSTNAME'"
echo "Next steps:"
echo "  1. Log out and back in (so docker group takes effect), or run: newgrp docker"
echo "  2. Set a Samba password for each NAS user:"
for nas_user in "${NAS_USERS[@]}"; do
    echo "       sudo smbpasswd -a $nas_user"
done
echo "  3. Set a static IP via your router's DHCP reservation"
echo "  4. Review .env files in services/ and adjust as needed"
echo "  5. Start Docker services:"
echo "       cd $REPO_DIR"
echo "       make up-tailscale"
echo "       make up-filebrowser"
echo "  6. Access FileBrowser at: http://$HOSTNAME.local:8082"
echo "     (default login: admin / admin — change on first login)"
echo "  7. Connect to NAS shares via Samba (Tailscale only):"
echo "     NOTE: Samba is bound to the Tailscale interface only."
echo "     All clients must be on your tailnet to connect."
echo ""
echo "     macOS:"
echo "       Finder -> Go -> Connect to Server (Cmd+K)"
echo "       Enter: smb://$HOSTNAME/<username>"
echo "       Log in with the Samba username and password"
echo "       Check 'Remember this password in my keychain' to save credentials"
echo ""
echo "     iOS (Files app):"
echo "       Open Files -> tap '...' (top-right) -> Connect to Server"
echo "       Enter: smb://$HOSTNAME/<username>"
echo "       Log in with the Samba username and password"
echo ""
echo "     Available shares (not browseable — type the path directly):"
for nas_user in "${NAS_USERS[@]}"; do
    echo "       smb://$HOSTNAME/$nas_user  (private)"
done
echo "       smb://$HOSTNAME/shared   (shared)"
echo ""
