# Arr Stack Setup — Automated Media Management on Pi 5

The arr stack runs on the Pi 5 NAS (`dragospi5`, `192.168.50.3`) and automates torrent-based media downloads into the same media folders that Jellyfin reads via NFS on the NUC.

## Architecture

```
Jellyseerr (request UI) → Radarr/Sonarr → Prowlarr (finds torrents) → qBittorrent (downloads)
                               ↓                                              ↓
                    hardlinks completed downloads from         /media/downloads/{movies,tv-shows}
                               ↓                                              ↓
                    /media/movies  /media/tv-shows  ←── same filesystem, instant hardlinks
                               ↓             ↖── Bazarr adds .srt subtitles next to each video
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
| Bazarr | 6767 | Subtitle automation — fetches and syncs subtitles for everything Radarr/Sonarr import |

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

SSH into the Pi 5 (`192.168.50.3`):

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

Open <http://192.168.50.3:8083>.

1. Check container logs for the temporary admin password: `docker logs qbittorrent`
2. Log in and change the admin password under **Tools > Options > Web UI**
3. Under **Tools > Options > Downloads**, set the default save path to `/media/downloads`
4. In the **main view left sidebar**, right-click and select **New Category**:
   - Category `movies` with save path `/media/downloads/movies`
   - Category `tv-shows` with save path `/media/downloads/tv-shows`
5. Under **Tools > Options > Downloads**, enable **Excluded file names** and add one pattern per line:
   ```
   *.exe
   *.scr
   *.bat
   *.cmd
   *.lnk
   *.vbs
   *.msi
   *.com
   ```
   Fake releases often bundle malware executables; Sonarr/Radarr then block the import with "Found executable file with extension '.exe'". This setting is stored in `data/qbittorrent` and is lost only if that directory is wiped, so redo it on fresh installs.

## Step 4 — Configure Prowlarr

Open <http://192.168.50.3:9696>.

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

Open <http://192.168.50.3:7878>.

1. Set up authentication when prompted
2. **Add download client**: Settings > Download Clients > Add > qBittorrent
   - Host: `qbittorrent`
   - Port: `8083`
   - Username/password: your qBittorrent credentials
   - Category: `movies`
3. **Add root folder**: Settings > Media Management > Add Root Folder > `/media/movies`

## Step 6 — Configure Sonarr

Open <http://192.168.50.3:8989>.

1. Set up authentication when prompted
2. **Add download client**: Settings > Download Clients > Add > qBittorrent
   - Host: `qbittorrent`
   - Port: `8083`
   - Username/password: your qBittorrent credentials
   - Category: `tv-shows`
3. **Add root folder**: Settings > Media Management > Add Root Folder > `/media/tv-shows`

## Step 7 — Configure Jellyseerr

Open <http://192.168.50.3:5055>.

1. Select **Jellyfin** as your media server during setup
2. Enter the Jellyfin server URL: `http://192.168.50.4:8096` (NUC)
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

## Step 8 — Configure Bazarr

Open <http://192.168.50.3:6767>. Bazarr mounts `/media` at the same path as Radarr and Sonarr, so no path mappings are needed.

1. **Turn on login first**: Settings > Application > General tab, scroll to Security > Authentication **Form**, set a username and password, Save. Bazarr ships with no authentication.
2. **Jobs**: Settings > Application > General tab > Jobs Manager > **Concurrent Jobs** `1`. The default (4 on a Pi 5) runs four searches or syncs at once, each reading video from the single HDD.
3. **Languages**: Settings > Languages
   - **Selection** tab > **Languages Filter**: add English. Leave **Single Language** off, so files are saved as `<video>.en.srt` and Jellyfin labels the track English
   - **Profiles** tab: add an `English` profile with English, Subtitles Type **Normal or hearing-impaired**
   - **Default Language Profiles For Newly Added Shows**: enable **Series** and **Movies** and select the profile for each, so new imports get subtitles automatically
4. **Providers**: Settings > Providers — add several, so one provider's daily limit or outage doesn't stall searches:
   - **OpenSubtitles.com** — free account (enter the username, not the email); the free tier caps daily downloads
   - **SubDL** — free account; generate an API key in its profile settings
   - **Gestdown (Addic7ed proxy)** — TV shows, no account needed
   - **YIFY Subtitles** — movies, no account needed
5. **Embedded subtitles**: Settings > Subtitles > Files — keep **Treat Embedded Subtitles as Downloaded** on (text tracks inside the file already count), and enable **Ignore Embedded PGS Subtitles** and **Ignore Embedded VobSub Subtitles**. Those are images: Jellyfin must burn them into the video, which forces a transcode, so Bazarr should fetch a text `.srt` instead.
6. **Search**: Settings > Subtitles > Search — keep the defaults (minimum score 90% episodes / 70% movies, Adaptive Searching on) and turn off **Upgrade Manually Downloaded or Translated Subtitles**, so subtitles you picked by hand are not replaced.
7. **Sonarr**: Settings > Library > Sonarr > Enabled
   - Address: `sonarr`, Port: `8989`
   - API key: copy from Sonarr (Settings > General > API Key)
   - Test, then Save
8. **Radarr**: Settings > Library > Radarr > Enabled
   - Address: `radarr`, Port: `7878`
   - API key: copy from Radarr (Settings > General > API Key)
   - Test, then Save
9. **Jellyfin**: Settings > Integrations > Jellyfin > Enabled
   - Server URL: `http://192.168.50.4:8096`
   - API Key: create one in Jellyfin (Dashboard > API Keys)
   - Click **Test Connection** (the library pickers appear only after it succeeds), then select the movie and series libraries, enable the metadata refresh for both, and keep the notify method **Immediate**
   - Jellyfin reads the media over NFS, which gives it no file-change notifications, so without this new subtitles only appear after its next scheduled library scan
10. **Existing library**: Series and Movies list everything Sonarr and Radarr know about. Select > select all matching the filter > **Change Profile** > pick the profile > Save, so titles imported before Bazarr also get subtitles.
11. **Sync (after the backfill)**: leave automatic sync off while Bazarr works through the existing library. Once the queue settles, enable Settings > Subtitles > Processing > Audio Synchronization > **Enable Automatic Subtitles Audio Synchronization** with **Series Score Threshold For Audio Sync** `96` and **Movies Score Threshold For Audio Sync** `86`. Bazarr syncs only subtitles scoring at or below the threshold, and the defaults (90/70) equal the minimum download scores, so at the defaults almost nothing gets synced; higher thresholds sync the lower-scored, likely mistimed downloads and skip near-perfect matches. Each sync decodes the video's audio; the container is capped at two cores. A single mistimed subtitle can be synced by hand from the title's page at any time.

If you keep Jellyfin's OpenSubtitles plugin for manual searches, give it a different OpenSubtitles account than Bazarr, since both draw on the same daily download limit.

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

All services are on the `homelab` Docker network and can reach each other by container name (e.g. `qbittorrent`, `prowlarr`, `radarr`, `sonarr`, `bazarr`). If a service can't connect to another, verify they're all on the same network:

```bash
docker network inspect homelab
```
