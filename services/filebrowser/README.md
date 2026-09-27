# Filebrowser

Web-based file manager for the NAS. Runs [FileBrowser Quantum](https://github.com/gtsteffaniak/filebrowser) (`ghcr.io/gtsteffaniak/filebrowser`), a maintained fork of the original filebrowser, which was archived upstream in 2026 with unpatched vulnerabilities.

## Quantum Image Paths

- Config: `./config.yaml` mounted at `/home/filebrowser/data/config.yaml` (the image's default `FILEBROWSER_CONFIG` path)
- Database: `./data/database.db` mounted at `/database/database.db` (set via `server.database` in `config.yaml`)
- Cache + search index: `./data/tmp` (`server.cacheDir: /database/tmp`). The image default (`/home/filebrowser/tmp`) is writable only by UID 1000, so any other `PUID` crashes at startup with `cacheDir failed to create cache directory`.
- The image has no PUID/PGID support; compose sets `user: "${PUID}:${PGID}"` directly.
- Health endpoint: `/health`

## Migration Notes (from filebrowser v2)

- The v2 database (`data/filebrowser.db`) is **not compatible** and is kept only as a backup — Quantum creates a fresh `database.db` on first start.
- Default admin credentials are `admin`/`admin` (override with `auth.adminUsername`/`auth.adminPassword` in `config.yaml`). Change the password immediately after first login.
- Users must be recreated in the UI (Settings → User Management) with the same scopes as before.

## User Scopes

The single source is `/srv` (`defaultUserScope: "/"`), so scopes work as before: set each user's scope to `/nas-hdd/<username>`. They see their own files plus the `shared` symlink, which is followed transparently:

```
/mnt/nas-hdd/x/shared -> ../shared
/mnt/nas-hdd/y/shared -> ../shared
/mnt/nas-hdd/z/shared -> ../shared
```

To add a new user:
```bash
ln -s /mnt/nas-hdd/shared /mnt/nas-hdd/<username>/shared
```
Then create the user in the UI with scope `/nas-hdd/<username>`.

Note: Quantum supports multiple scopes per user natively, so the symlink workaround can be retired later if desired.
