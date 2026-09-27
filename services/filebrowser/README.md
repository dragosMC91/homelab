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

Two sources in `config.yaml`, each with its own per-user scope:

| Source | Path | Granted | User scope |
|--------|------|---------|------------|
| `srv` | `/srv` (both disks) | Manually (`defaultEnabled: false`) | `/nas-hdd/<username>` |
| `shared` | `/srv/nas-hdd/shared` | Every user automatically (`defaultEnabled: true`), existing users included on the next start | `/` |

To add a new user: Settings → User Management → New, then add an `srv` scope of `/nas-hdd/<username>`. `shared` is added on its own. A user created without an `srv` scope sees only `shared` — safe by default.

The v2-era `<user>/shared -> ../shared` symlinks do **not** work in Quantum: it refuses symlinks that resolve outside the user's scope. Samba has its own `[shared]` share and never used them, so they can be removed: `sudo unlink /mnt/nas-hdd/<username>/shared`.

Writing to `shared` (`root:nasusers`, mode 2775) requires `PGID` in `.env` to be the `nasusers` GID (`getent group nasusers`); otherwise it is read-only in FileBrowser.
