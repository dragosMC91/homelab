# Homelab

Portable, modular homelab configuration running Docker containers on macOS (via OrbStack), Intel NUC, and Raspberry Pi — all packed into a desk-side mini rack.

Self-hosted everything: DNS ad-blocking, media streaming, photo management, NAS, and monitoring — no subscriptions, no cloud lock-in, no dependency on US services that can rug-pull pricing or access at any time. Your data stays on hardware you own.

Clone the repo, pick the services you need, and run `make up`.

## Table of Contents

- [The Rack](#the-rack)
- [Architecture](#architecture)
- [Services](#services)
- [Hosts](#hosts)
- [Tailscale Auth Key Setup](#tailscale-auth-key-setup)
- [Prerequisites](#prerequisites)
- [Quickstart (macOS)](#quickstart-macos)
- [Quickstart (Intel NUC)](#quickstart-intel-nuc)
- [Quickstart (Raspberry Pi 3B+ — pi-infra)](#quickstart-raspberry-pi-3b--pi-infra)
- [Usage](#usage)
- [Maintenance](#maintenance)
- [Adding a New Service](#adding-a-new-service)
- [3D Printed Parts](#3d-printed-parts)

## The Rack

A **GeeekPi DeskPi RackMate T1 Plus** mini rack housing all compute, storage, and networking in a compact desk-side form factor. Active cooling throughout with **ARCTIC P12 Pro PST** fans. Power distribution via **2x DIGITUS 4-Way Power Strip (1U)** mounted in the rear, alongside the MacBook cooling fan.

<p align="center">
  <img src="docs/images/homelab-front.jpeg" alt="Rack front view" width="220"/>
  &nbsp;&nbsp;
  <img src="docs/images/homelab-top.jpeg" alt="Rack back top" width="220"/>
  &nbsp;&nbsp;
  <img src="docs/images/homelab-back.jpeg" alt="Rack back view" width="220"/>
</p>

<p align="center">
  <img src="docs/images/internals-sketch.png" alt="Rack internals diagram" width="500"/>
</p>

### Layer Breakdown

| Layer | Position | Contents |
|-------|----------|----------|
| **L0** | Bottom | 2x intake fans (base airflow) |
| **L1** | — | 2x HDDs (horizontal) + 1x vertical fan behind them; Penta SATA HAT with vertical SSDs beside the HDD cage |
| **L2** | — | 1x horizontal fan blowing down onto the Penta SATA HAT and SSDs |
| **L3** | — | Network switch + Noctua NA-FC1 fan controller |
| **L4** | — | Patch panel |
| **L5** | Top | Intel NUC 8 Pro |
| **Roof** | — | 1x intake fan blowing down onto the NUC |
| **Back wall** | — | MacBook Pro M1 (clamshell) + 1x fan blowing directly onto it from inside the rack |

An **Eaton Ellipse PRO** UPS sits beside the rack for power protection.

## Architecture

```
homelab/
  Makefile                          # Orchestration layer (make up, make down, etc.)
  scripts/
    setup-nuc.sh                    # Intel NUC first-time setup (Docker, VA-API, hostname)
    setup-pi.sh                     # Raspberry Pi first-time setup (Docker, hostname)
  services/
    adguard-home/docker-compose.yml # Network-wide DNS ad blocker
    tailscale/docker-compose.yml    # Mesh VPN for secure remote access
    uptime-kuma/docker-compose.yml  # Uptime monitoring dashboard
```

All services that expose ports share an external Docker network (`homelab`) so they can communicate with each other. Tailscale uses `network_mode: host` for subnet routing and is excluded from the shared network.

Each service is fully self-contained in its own directory with its own compose file, `.env.example`, `.gitignore`, and `data/` directory for persistent volumes.

## Services

| Service | Description | Ports | Host | Docs |
|---------|-------------|-------|------|------|
| **AdGuard Home** | Network-wide DNS ad blocker | `53` (DNS) / `5353` (macOS), `3000` (Web UI) | `pi-infra` | [adguard-home](services/adguard-home/) |
| **Tailscale** | Mesh VPN / secure remote access | Host networking | All nodes | [tailscale](services/tailscale/) |
| **Jellyfin** | Media streaming server (HW transcoding) | `8096` (Web UI), `7359/udp` (discovery) | `nuc` | [jellyfin](services/jellyfin/) |
| **Immich** | Self-hosted photo & video management | `2283` (Web UI) | MacBook Pro M1 | [immich](services/immich/) |
| **Filebrowser** | Web-based file manager (Tailscale-only) | `8082` | `dragospi5` | [filebrowser](services/filebrowser/) |
| ***arr* stack** | Prowlarr, Radarr, Sonarr, Seerr, qBittorrent | `9696`, `7878`, `8989`, `5055`, `8083` | `dragospi5` | [arr-stack](services/arr-stack/) |
| **Uptime Kuma** | Uptime monitoring dashboard | `3001` (Web UI) | `nuc` | [uptime-kuma](services/uptime-kuma/) |

## Hosts

| Host | Hardware | OS | Services | Hostname |
|------|----------|----|----------|----------|
| Raspberry Pi 3B+ | 1GB RAM | RPi OS Lite 64-bit | AdGuard Home, Tailscale | `pi-infra` |
| Raspberry Pi 3B+ (backup) | 1GB RAM | RPi OS Lite 64-bit | AdGuard Home (DNS backup), Tailscale | — |
| Intel NUC 8 Pro | i3-8145U, 16GB RAM | Ubuntu Server 24.04 LTS | Jellyfin, Uptime Kuma, Tailscale | `nuc` |
| Raspberry Pi 5 | 4GB RAM, Penta SATA HAT | RPi OS Lite 64-bit | NAS (Samba/NFS), *arr stack, Tailscale | `dragospi5` |
| MacBook Pro M1 | 32GB RAM | macOS (OrbStack) | Immich, Tailscale | — |
| Mac Mini 2018 | Intel i5, 8GB RAM | — | Backup homelab device, Tailscale | — |

Tailscale runs on every node for secure remote access. AdGuard Home is configured as the Tailscale DNS server so all remote devices (phone, laptop) get network-wide ad-blocking; a second Pi 3B+ runs AdGuard Home as a DNS backup.

## Tailscale Auth Key Setup

Tailscale requires an **auth key** (`TS_AUTHKEY`) so each node can join your tailnet without interactive browser login. This is the only secret you need to configure before deploying.

### Generate a key

1. Go to [Tailscale Admin > Settings > Keys](https://login.tailscale.com/admin/settings/keys)
2. Click **Generate auth key...**
3. Configure these settings:
   - **Reusable** — enable this so you can use the same key on all nodes instead of generating one per device
   - **Ephemeral** — enable this so nodes are automatically removed from your tailnet when they go offline for 30+ minutes (useful for containers that get recreated on redeploy)
   - **Expiry** — set to the maximum (90 days)
4. Copy the key (starts with `tskey-auth-`)

### Use the key

Set `TS_AUTHKEY` in each node's `services/tailscale/.env`:

```bash
# Same key works on all nodes (reusable)
TS_AUTHKEY=tskey-auth-kXXXXXXXXXXXXXXXXXX
```

You can use the **same reusable key** on every node — no need to generate a separate key per device.

### Key lifecycle

- The auth key is only used on **first join** (or if `services/tailscale/data/` is wiped). After that, the node authenticates via its stored state in `data/`.
- Running nodes are **not affected** when a key expires. They keep their connection via the persisted state.
- When the key expires after 90 days, generate a new one and update the `.env` files. You only need the new key if you're adding a new node or recreating one from scratch.
- If you delete the `data/` directory, the node will need to re-authenticate with a valid key.

## Prerequisites

All hosts need **Git**, **Docker** (with Compose), and **Make**. You also need a free [Tailscale](https://tailscale.com/) account for the mesh VPN.

| Host | OS | Extra Requirements |
|------|----|--------------------|
| MacBook Pro M1 | macOS + [OrbStack](https://orbstack.dev/) | [Homebrew](https://brew.sh/) |
| Intel NUC 8 Pro | Ubuntu Server 24.04 LTS | Intel VA-API drivers (installed by `setup-nuc.sh`) |
| Raspberry Pi 3B+ | RPi OS Lite 64-bit | SD card, cgroup memory limits enabled |
| Raspberry Pi 5 | RPi OS Lite 64-bit | Penta SATA HAT for NAS drives |

## Quickstart (macOS)

### 1. Install OrbStack

[OrbStack](https://orbstack.dev/) is the Docker runtime used on the MacBook Pro M1 — lighter and faster than Docker Desktop.

```bash
brew install orbstack
open -a OrbStack
```

OrbStack ships with `docker` and `docker compose` CLIs.

### 2. Clone and set up

```bash
git clone https://github.com/<your-username>/homelab.git
cd homelab
make setup
```

This creates the shared Docker network and copies `.env.example` to `.env` in each service directory.

### 3. Configure

Edit the `.env` file in each service directory you want to run. At minimum:

- **Tailscale**: set `TS_AUTHKEY` in `services/tailscale/.env` (get a key from [Tailscale Admin](https://login.tailscale.com/admin/settings/keys))
- **AdGuard Home**: set `HOST_DNS_PORT=5353` in `services/adguard-home/.env` (macOS mDNSResponder occupies port 53)

### 4. Start services

```bash
# Start everything
make up

# Or start individual services
make up-adguard-home
make up-tailscale
make up-uptime-kuma
```

## Quickstart (Intel NUC)

### 1. Install Ubuntu Server

Download [Ubuntu Server 24.04 LTS](https://ubuntu.com/download/server) and flash it onto a USB stick. Boot the NUC from it and install to the internal drive.

During installation:
- Enable OpenSSH server
- Set hostname to `nuc`
- Set username and password
- Set timezone to `Europe/Bucharest`

### 2. SSH in and clone

```bash
ssh <your-user>@nuc.local
git clone https://github.com/<your-username>/homelab.git
cd homelab
```

### 3. Run the setup script

```bash
./scripts/setup-nuc.sh --hostname nuc
```

This sets the hostname, installs Intel VA-API drivers (for Jellyfin hardware transcoding), installs Docker, creates the Docker network, and copies `.env.example` files.

Log out and back in after setup so the `docker` group takes effect.

### 4. Verify hardware transcoding

```bash
vainfo
```

You should see VA-API profiles listed (H264, HEVC, VP9). Also confirm `/dev/dri/renderD128` exists -- Jellyfin needs this device passed through for HW transcoding.

### 5. Set a static IP

Assign a static IP to the NUC via your router's DHCP reservation (bind the NUC's MAC address to a fixed IP).

### 6. Configure and start

```bash
# Set Tailscale auth key and hostname
nano services/tailscale/.env
# TS_AUTHKEY=tskey-auth-...
# TS_HOSTNAME=nuc

# Start services
make up-tailscale
make up-uptime-kuma
make up-jellyfin       # Once Jellyfin service is added
```

## Quickstart (Raspberry Pi 3B+ — pi-infra)

This is the first node to deploy. It runs AdGuard Home (DNS ad-blocker) and Tailscale (VPN).

### 1. Flash the SD card

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to flash **Raspberry Pi OS Lite (64-bit)** onto the SD card.

In Imager's advanced settings (gear icon):
- Enable SSH
- Set hostname to `pi-infra`
- Set username and password
- Configure Wi-Fi (if not using Ethernet)
- Set timezone to `Europe/Bucharest`

### 2. Boot and connect

Insert the SD card, power on, and SSH in:

```bash
ssh <your-user>@pi-infra.local
```

### 3. Clone and run the setup script

```bash
git clone https://github.com/<your-username>/homelab.git
cd homelab
./scripts/setup-pi.sh --hostname pi-infra
```

This sets the hostname, configures 2GB swap, installs Docker, frees port 53 for AdGuard Home, creates the Docker network, and copies `.env.example` files.

Log out and back in after setup so the `docker` group takes effect.

### 4. Enable cgroup memory limits

Raspberry Pi OS does not enable cgroup memory accounting by default. Without this, Docker cannot enforce container memory limits (`mem_limit` / `deploy.resources.limits.memory`) and will log warnings on `docker compose up`.

Append these parameters to the **existing single line** in `/boot/firmware/cmdline.txt`:

```
cgroup_enable=memory cgroup_memory=1
```

Then reboot:

```bash
sudo reboot
```

Verify after reboot:

```bash
docker info | grep -i cgroup
# Should show: Cgroup Version: 2 (or 1) without warnings
```

> **Note:** This applies to all Raspberry Pi nodes (pi-infra, pi-nas). Without it, containers still run but are not memory-capped — risky on low-RAM Pis.

### 5. Set a static IP

Assign a static IP to the Pi via your router's DHCP reservation (bind the Pi's MAC address to a fixed IP). This is essential since this Pi will serve DNS for your entire network.

All Pis should use Ethernet and disable WiFi to avoid dual-interface issues (the router may show stale DHCP entries from the WiFi interface):
```bash
echo "dtoverlay=disable-wifi" | sudo tee -a /boot/firmware/config.txt
sudo reboot
```

### 6. Configure and start

```bash
# Set Tailscale auth key and hostname
nano services/tailscale/.env
# TS_AUTHKEY=tskey-auth-...
# TS_HOSTNAME=pi-infra

# Start Tailscale first, then AdGuard Home
make up-tailscale
make up-adguard-home
```

### 7. Configure AdGuard Home

Open `http://pi-infra.local:3000` in your browser and complete the setup wizard.

### 8. Point your network to AdGuard

In your router's DHCP settings, set the Pi's static IP as the primary DNS server. All devices on the network will now use AdGuard Home for DNS.

### 9. Configure Tailscale DNS (remote ad-blocking)

In the [Tailscale admin console](https://login.tailscale.com/admin/dns):
1. Add a **Global Nameserver** — enter the Pi's Tailscale IP (find it with `tailscale ip -4` on the Pi)
2. Enable **Override local DNS** so all Tailscale-connected devices use AdGuard
3. Now when you connect via Tailscale on your iPhone/laptop, DNS queries go through AdGuard — ad-blocking everywhere

## Usage

```bash
make help             # Show all available commands

# All services
make up               # Start all services
make down             # Stop all services
make restart          # Restart all services
make pull             # Pull latest images
make status           # Show running containers

# Individual services
make up-adguard-home  # Start AdGuard Home
make down-adguard-home
make logs-adguard-home
make restart-adguard-home

make up-tailscale
make up-uptime-kuma
# ... same pattern for all services
```

## Maintenance

### Update all services to latest images

```bash
make pull
make restart
```

### Update a single service

```bash
make pull-adguard-home
make restart-adguard-home
```

### View logs

```bash
make logs-adguard-home
make logs-uptime-kuma
```

### Full cleanup

```bash
make clean            # Stop all services and remove the homelab network
```

## Adding a New Service

1. Create a new directory under `services/`:
   ```
   services/my-service/
     docker-compose.yml
     .env.example
     .gitignore
     data/.gitkeep
   ```

2. In the compose file, use the shared `homelab` network:
   ```yaml
   networks:
     homelab:
       external: true
   ```

3. Add a `.gitignore` to exclude `data/*` and `.env`, keeping `!data/.gitkeep`.

4. The Makefile auto-discovers services -- no changes needed. Just run:
   ```bash
   make setup
   make up-my-service
   ```

## 3D Printed Parts

Custom 3D-printed mounts and adapters for the rack live in [`3d-prints/`](3d-prints/). STL files are ready to slice and print.

| Part | STL | Description |
|------|-----|-------------|
| NAS 5U Slot | [`nas_slot_5u.stl`](3d-prints/nas_slot_5u.stl) | 5U caddy holding the HDDs, Penta SATA HAT, and vertical fan (L1) |
| Switch + Fan Controller Mount | [`TL-SG108+NA-FC1-v6.stl`](3d-prints/TL-SG108+NA-FC1-v6.stl) | Combined mount for the TP-Link TL-SG108 switch and Noctua NA-FC1 (L3) |
| 120mm Fan Rackmount | [`10-Inch-120mm-Fan-Rackmount.stl`](3d-prints/10-Inch-120mm-Fan-Rackmount.stl) | 10-inch rack panel with 120mm fan cutout (L2 horizontal fan) |
| Back Exhaust Fan Mount | [`120mm_back_exhaust.stl`](3d-prints/120mm_back_exhaust.stl) | Rear 120mm fan mount for MacBook cooling (back wall) |
| Dual Laptop Bracket (Left) | [`DualLaptopBracket-L.stl`](3d-prints/DualLaptopBracket-L.stl) | Left bracket for the clamshell MacBook mount |
| Dual Laptop Bracket (Right) | [`DualLaptopBracket-R.stl`](3d-prints/DualLaptopBracket-R.stl) | Right bracket for the clamshell MacBook mount |

### Reference Designs

Starting points used for some of the custom parts above:

- [Dual Laptop Stand](https://www.thingiverse.com/thing:4230307) — base design for the MacBook clamshell brackets
- [Blank 10-inch Rack 3U Plate](https://www.printables.com/model/1629106-blank-10-inch-rack-3u-plate-fits-core-one) — blank plate used as a starting template
- [10-inch Rack 1U 120mm Fan Mount](https://makerworld.com/en/models/1962259-10-inch-rack-1u-120mm-fan-mount#profileId-2109254) — fan mount panel reference
- [Customizable Fan Mount Plates for 10-inch Rack](https://makerworld.com/en/models/1878745-customizable-fan-mount-plates-for-10-inch-rack#profileId-2086173) — parametric fan mount reference
