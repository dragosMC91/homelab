# Immich

Self-hosted photo and video management, running on the MacBook Pro M1 (32GB) in clamshell mode via OrbStack.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  MacBook Pro M1 (OrbStack)                              │
│                                                         │
│  ┌──────────────┐      ┌──────────────────────────┐     │
│  │ immich-server│─────▶│ immich-machine-learning  │     │
│  │  :2283       │      │  :3003                   │     │
│  └──────┬───────┘      │  CLIP + face recognition │     │
│         │               └─────────────────────────┘     │
│         │                                               │
│  ┌──────▼─────────┐      ┌──────────────┐               │
│  │ immich-postgres│      │ immich-redis │               │
│  │  pgvecto.rs    │      │  job queue   │               │
│  └────────────────┘      └──────────────┘               │
│                                                         │
│  Network: homelab (external)                            │
└─────────────────────────────────────────────────────────┘
         │
         │ Tailscale (tag:server)
         ▼
    Accessible from tailnet only
```

Four containers, all on the shared `homelab` Docker network:

| Container | Role | Resource limits |
|-----------|------|-----------------|
| **immich-server** | API, web UI, thumbnail/video processing | 6GB RAM, 6 CPUs |
| **immich-machine-learning** | CLIP embeddings, facial recognition | 6GB RAM, 6 CPUs |
| **immich-postgres** | PostgreSQL 16 + pgvecto.rs (vector search) | 2GB RAM, 2 CPUs |
| **immich-redis** | Job queue (no persistence, ephemeral) | 512MB RAM, 1 CPU |

Total resource ceiling: ~14.5GB RAM — leaves ~17GB for macOS, OrbStack, and Tailscale on the 32GB machine.

## Setup

```bash
# From the repo root
make setup          # Creates .env from .env.example
# Edit services/immich/.env — at minimum, change DB_PASSWORD
make up-immich
```

The compose file has **no default for `DB_PASSWORD`** — it will fail to start if `.env` is missing or the password is unset. This is intentional.

## Upload storage

By default, photos land in `./data/upload/`. For a real library, override `UPLOAD_LOCATION` in `.env` to point at a larger volume:

```bash
# Example: external SSD mounted on macOS
UPLOAD_LOCATION=/Volumes/photos/immich

# Example: NFS mount from the RPi 5 NAS
UPLOAD_LOCATION=/mnt/nas/immich
```

## Database backups

The Postgres container mounts `./data/backups/` at `/backups` inside the container. Run a manual dump with:

```bash
docker exec immich-postgres pg_dump -U immich -Fc immich > services/immich/data/backups/immich-$(date +%F).dump
```

Restore with:

```bash
docker exec -i immich-postgres pg_restore -U immich -d immich < services/immich/data/backups/immich-YYYY-MM-DD.dump
```

Photos are the crown-jewel asset of this homelab — back up both the upload directory and the database regularly.

## External SSD backup

A second copy of the upload directory lives on an external USB-C SSD, synced on a schedule via `rsync`. The internal SSD is already protected by FileVault — the external drive needs its own encryption.

### Encrypting the external SSD

#### Option A — Fresh drive (wipe and encrypt)

Open Disk Utility, select the external drive, click **Erase**, and choose:

- **Format**: APFS (Encrypted)
- **Scheme**: GUID Partition Map

Set a strong password when prompted. macOS stores it in your login keychain, so the volume auto-unlocks when you log in.

#### Option B — Existing volume (encrypt in place, no data loss)

```bash
diskutil apfs encryptVolume /Volumes/external-ssd -user disk
```

macOS prompts for a password, then encrypts in the background. The drive remains usable during conversion. Monitor progress with:

```bash
diskutil apfs list | grep -A3 "Encryption"
```

### Keychain auto-unlock

After setting the encryption password, macOS offers to store it in your login keychain. Accept this — the volume will auto-mount and decrypt on login without prompting.

This means the drive is accessible while the user session is active (which is what you want for scheduled `rsync`), but encrypted at rest if:

- The drive is physically removed and plugged into another machine
- The Mac is powered off or at the login screen (FileVault locks the keychain)

### Syncing uploads to the external SSD

```bash
rsync -a --delete /path/to/immich/upload/ /Volumes/external-ssd/immich-backup/
```

Automate this with a launchd plist or cron job. The sync only works while the volume is unlocked (i.e., user session is active), which naturally gates access.

### What's protected and what isn't

| Scenario | Internal SSD | External SSD |
|----------|-------------|-------------|
| Mac powered off / login screen | FileVault encrypted | APFS encrypted |
| Drive physically stolen | Unreadable without password | Unreadable without password |
| User session active (logged in) | Decrypted, accessible | Decrypted, auto-mounted |
| Someone with your Mac login password | Full access | Full access (via keychain) |

### Recommendations

- Use a **different password** for the external SSD than your Mac login — so a compromised login password doesn't immediately unlock the backup drive. You'll need to enter it manually after each reboot, but that only happens on power cycles (rare for a clamshell server).
- **Don't store the external SSD password in keychain** if you go this route — enter it manually via Disk Utility or `diskutil apfs unlockVolume` after each reboot.
- Keep the external SSD **physically attached** to the MacBook. If you also want an offsite copy, periodically `rsync` to a second drive and store it elsewhere.
- Test recovery: unplug the SSD, plug it into another Mac, confirm it asks for the password.

## Network access

Immich is reachable only via Tailscale. The MacBook runs Tailscale with `--advertise-tags=tag:server`, and ACLs restrict access to tailnet members. There is no port exposed to the LAN beyond what Tailscale tunnels.

See [macbook-clamshell-server.md](macbook-clamshell-server.md) for hardware setup, power management, battery health (AlDente), and remote access details.
