# Homelab

Portable, modular homelab configuration running Docker containers on macOS (via Colima), Intel NUC, and Raspberry Pi.

Clone the repo, pick the services you need, and run `make up`.

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

| Service | Description | Ports | Docs |
|---------|-------------|-------|------|
| **AdGuard Home** | Network-wide DNS ad blocker | `53` (DNS, NUC) / `5353` (macOS), `3000` (Web UI) | [adguard-home](services/adguard-home/) |
| **Tailscale** | Mesh VPN / secure remote access | Host networking | [tailscale](services/tailscale/) |
| **Uptime Kuma** | Uptime monitoring dashboard | `3001` (Web UI) | [uptime-kuma](services/uptime-kuma/) |

## Hosts

| Host | Hardware | OS | Services | Hostname |
|------|----------|----|----------|----------|
| Raspberry Pi 3B+ | 1GB RAM | RPi OS Lite 64-bit | AdGuard Home, Tailscale | `pi-infra` |
| Intel NUC 8 Pro | i3-8145U, 16GB RAM | Ubuntu Server 24.04 LTS | Jellyfin, Uptime Kuma, Tailscale | `nuc` |
| Raspberry Pi 5 | 4GB RAM, Penta SATA HAT | RPi OS Lite 64-bit | NAS (Samba/NFS), Tailscale | `pi-nas` |
| Mac Mini 2018 | Intel i5, 8GB RAM | — | Future / on-demand | — |
| MacBook Pro M1 | 32GB RAM | macOS | On-demand compute (Immich) | — |

Tailscale runs on every node for secure remote access. AdGuard Home is configured as the Tailscale DNS server so all remote devices (phone, laptop) get network-wide ad-blocking.

## Prerequisites

### macOS

- [Homebrew](https://brew.sh/) installed
- Git installed

### Intel NUC

- Intel NUC 8 Pro (or similar x86_64 mini PC)
- [Ubuntu Server 24.04 LTS](https://ubuntu.com/download/server) installed (minimal, no desktop)
- USB stick for OS installation

### Raspberry Pi 3B+ (pi-infra)

- Raspberry Pi 3B+ (1GB RAM)
- Raspberry Pi OS Lite 64-bit (no desktop)
- SD card for boot + storage

### Raspberry Pi 5 (pi-nas)

- Raspberry Pi 5 (4GB RAM)
- Raspberry Pi OS Lite 64-bit (no desktop)
- USB SSD recommended for boot + storage
- Penta SATA HAT for NAS drives

## Quickstart (macOS)

### 1. Install Colima and Docker

```bash
brew install colima docker docker-compose
colima start --cpu 2 --memory 4 --disk 60
```

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

### 4. Set a static IP

Assign a static IP to the Pi via your router's DHCP reservation (bind the Pi's MAC address to a fixed IP). This is essential since this Pi will serve DNS for your entire network.

### 5. Configure and start

```bash
# Set Tailscale auth key and hostname
nano services/tailscale/.env
# TS_AUTHKEY=tskey-auth-...
# TS_HOSTNAME=pi-infra

# Start Tailscale first, then AdGuard Home
make up-tailscale
make up-adguard-home
```

### 6. Configure AdGuard Home

Open `http://pi-infra.local:3000` in your browser and complete the setup wizard.

### 7. Point your network to AdGuard

In your router's DHCP settings, set the Pi's static IP as the primary DNS server. All devices on the network will now use AdGuard Home for DNS.

### 8. Configure Tailscale DNS (remote ad-blocking)

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


