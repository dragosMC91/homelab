# Filebrowser

Web-based file manager for the NAS.

## User Scopes

Filebrowser allows only **one scope (directory) per user**. To give users access to both their personal folder and shared folders, symlinks are used on the host:

```
/mnt/nas-hdd/x/shared -> ../shared
/mnt/nas-hdd/y/shared  -> ../shared
/mnt/nas-hdd/z/shared  -> ../shared
```

Each user's scope is set to `/nas-hdd/<username>` in the Filebrowser UI. They see their own files plus the `shared` symlink, which Filebrowser follows transparently.

To add a new user:
```bash
ln -s /mnt/nas-hdd/shared /mnt/nas-hdd/<username>/shared
```
Then create the user in the Filebrowser UI with scope `/nas-hdd/<username>`.

## s6 Image Paths

The `v2-s6` image expects:
- Config: `/config/settings.json`
- Database: `/database/filebrowser.db`
- Listen address must be `0.0.0.0` (defaults to `127.0.0.1` otherwise)
