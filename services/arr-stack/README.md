# Arr Stack Setup — Automated Media Management on Pi 5

The arr stack runs on the Pi 5 NAS (`dragospi5`, `192.168.55.111`) and automates torrent-based media downloads into the same media folders that Jellyfin reads via NFS on the NUC.

## Architecture

```
Jellyseerr (request UI) → Radarr/Sonarr → Prowlarr (finds torrents) → qBittorrent (downloads)
                               ↓                                              ↓
                    hardlinks completed downloads from         /media/downloads/{movies,tv-shows}
                               ↓                                              ↓
                    /media/movies  /media/tv-shows  ←── same filesystem, instant hardlinks
                               ↓
                    Jellyfin (NUC) reads via NFS
```

All containers mount `/mnt/nas-hdd/media` as `/media`, so downloads and library folders share the same filesystem. This enables hardlinks — Radarr/Sonarr move completed downloads to the library instantly with zero extra disk usage.

## Services

| Service | Port | Role |
|---------|------|------|
| Jellyseerr | 5055 | Media request manager — users request movies/shows here |
| qBittorrent | 8083 | Torrent client |
| Prowlarr | 9696 | Indexer manager — syncs torrent sources to Radarr/Sonarr |
| Radarr | 7878 | Movie automation |
| Sonarr | 8989 | TV show automation |

## Prerequisites

The media LVM volume and NFS export should already be set up (see `services/jellyfin/README.md`). The media directory structure should look like:

```
/mnt/nas-hdd/media/
├── movies/
├── tv-shows/
├── music/
└── downloads/
    ├── movies/
    └── tv-shows/
```

## Step 1 — Create Download Directories

SSH into the Pi 5 (`192.168.55.111`):

```bash
mkdir -p /mnt/nas-hdd/media/downloads/{movies,tv-shows}
chown -R 1000:1000 /mnt/nas-hdd/media/downloads
```

## Step 2 — Deploy the Stack

```bash
cd ~/homelab/services/arr-stack
cp .env.example .env
make up-arr-stack
```

## Step 3 — Configure qBittorrent

Open <http://192.168.55.111:8083>.

1. Check container logs for the temporary admin password: `docker logs qbittorrent`
2. Log in and change the admin password under **Tools > Options > Web UI**
3. Under **Tools > Options > Downloads**, set the default save path to `/media/downloads`
4. In the **main view left sidebar**, right-click and select **New Category**:
   - Category `movies` with save path `/media/downloads/movies`
   - Category `tv-shows` with save path `/media/downloads/tv-shows`

## Step 4 — Configure Prowlarr

Open <http://192.168.55.111:9696>.

1. Set up authentication (username/password) when prompted
2. **Add indexers**: Settings > Indexers > Add Indexer — search and add your preferred torrent indexers
   - Note: some indexers (e.g. 1337x) are blocked by Cloudflare and won't work without FlareSolverr. Pick indexers that work without it, or add FlareSolverr later if needed
3. **Add Radarr as an app**: Settings > Apps > Add > Radarr
   - Prowlarr server: `http://prowlarr:9696`
   - Radarr server: `http://radarr:7878`
   - API key: copy from Radarr (Settings > General > API Key)
4. **Add Sonarr as an app**: Settings > Apps > Add > Sonarr
   - Prowlarr server: `http://prowlarr:9696`
   - Sonarr server: `http://sonarr:8989`
   - API key: copy from Sonarr (Settings > General > API Key)

This auto-syncs all your indexers to both Radarr and Sonarr.

## Step 5 — Configure Radarr

Open <http://192.168.55.111:7878>.

1. Set up authentication when prompted
2. **Add download client**: Settings > Download Clients > Add > qBittorrent
   - Host: `qbittorrent`
   - Port: `8083`
   - Username/password: your qBittorrent credentials
   - Category: `movies`
3. **Add root folder**: Settings > Media Management > Add Root Folder > `/media/movies`

## Step 6 — Configure Sonarr

Open <http://192.168.55.111:8989>.

1. Set up authentication when prompted
2. **Add download client**: Settings > Download Clients > Add > qBittorrent
   - Host: `qbittorrent`
   - Port: `8083`
   - Username/password: your qBittorrent credentials
   - Category: `tv-shows`
3. **Add root folder**: Settings > Media Management > Add Root Folder > `/media/tv-shows`

## Step 7 — Configure Jellyseerr

Open <http://192.168.55.111:5055>.

1. Select **Jellyfin** as your media server during setup
2. Enter the Jellyfin server URL: `http://192.168.55.111:8096` (NUC)
3. Sign in with your Jellyfin admin credentials and sync libraries
4. **Add Radarr**: Settings > Services > Add Radarr
   - Server: `http://radarr:7878`
   - API key: copy from Radarr (Settings > General > API Key)
   - Root folder: `/media/movies`
   - Quality profile: select your preferred profile
5. **Add Sonarr**: Settings > Services > Add Sonarr
   - Server: `http://sonarr:8989`
   - API key: copy from Sonarr (Settings > General > API Key)
   - Root folder: `/media/tv-shows`
   - Quality profile: select your preferred profile

## Troubleshooting

### "Directory does not appear to exist inside the container"

This health check warning means the download path doesn't exist on disk. Create the missing directories on the host:

```bash
mkdir -p /mnt/nas-hdd/media/downloads/{movies,tv-shows}
```

Then restart the affected container (`docker restart radarr` or `docker restart sonarr`).

### Cloudflare-blocked indexers in Prowlarr

Some public indexers use Cloudflare protection. Options:
- Use different indexers that don't have Cloudflare protection
- Add [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr) as a container and configure it as a proxy in Prowlarr under Settings > Indexers > Indexer Proxies

### Container connectivity

All services are on the `homelab` Docker network and can reach each other by container name (e.g. `qbittorrent`, `prowlarr`, `radarr`, `sonarr`). If a service can't connect to another, verify they're all on the same network:

```bash
docker network inspect homelab
```
