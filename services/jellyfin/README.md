# Jellyfin Setup — NFS Media Share from NAS to NUC

## Step 1 — Create a 2TB Media LVM Partition on the NAS (Pi 5)

LVM makes this easy to extend later. The volume group `nas-hdd` already exists.

SSH into the Pi 5 (`192.168.55.222`):

```bash
# Check available space in the volume group
sudo vgs

# Create a 2TB logical volume for media
sudo lvcreate -L 2T -n media nas-hdd

# Format it
sudo mkfs.ext4 /dev/nas-hdd/media

# Create mount point and mount
sudo mkdir -p /mnt/nas-hdd/media
sudo mount /dev/nas-hdd/media /mnt/nas-hdd/media

# Make it permanent
echo '/dev/nas-hdd/media /mnt/nas-hdd/media ext4 defaults 0 2' | sudo tee -a /etc/fstab

# Create subdirectories for Jellyfin
sudo mkdir -p /mnt/nas-hdd/media/{movies,tv-shows,music}
sudo chown -R 1000:1000 /mnt/nas-hdd/media
```

To extend later:

```bash
sudo lvextend -L +1T /dev/nas-hdd/media && sudo resize2fs /dev/nas-hdd/media
```

## Step 2 — Set Up NFS on the NAS to Export Media to the NUC

NFS is preferred over Samba for Linux-to-Linux — lower overhead, better performance.

SSH into the Pi 5 (`192.168.55.222`):

```bash
# Install NFS server
sudo apt-get install -y nfs-kernel-server

# Export the media directory to the NUC only
echo '/mnt/nas-hdd/media 192.168.55.111(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)' | sudo tee -a /etc/exports

# Apply and enable
sudo exportfs -ra
sudo systemctl enable --now nfs-kernel-server
```

## Step 3 — Mount NFS on the NUC

SSH into the NUC (`192.168.55.111`):

```bash
# Install NFS client
sudo apt-get install -y nfs-common

# Create mount point and mount
sudo mkdir -p /mnt/nas-media
sudo mount -t nfs 192.168.55.222:/mnt/nas-hdd/media /mnt/nas-media

# Make it permanent
echo '192.168.55.222:/mnt/nas-hdd/media /mnt/nas-media nfs defaults,_netdev,noexec,nosuid,nodev 0 0' | sudo tee -a /etc/fstab

# Verify
ls /mnt/nas-media/
# Should show: movies  tv-shows  music
```

## Step 4 — Prepare Host Permissions

Before starting the container, ensure the data directories are owned by the UID/GID the container runs as (1000:1000):

```bash
sudo chown -R 1000:1000 services/jellyfin/data
```

Without this, Jellyfin will crash on startup with `Access to the path '/config/log' is denied`.

## Step 5 — Deploy Jellyfin

On the NUC:

```bash
cd ~/homelab
cp services/jellyfin/.env.example services/jellyfin/.env
make up-jellyfin
```

Open <http://192.168.55.111:8096> to run the Jellyfin setup wizard. In the wizard, enable **VA-API hardware transcoding** under Playback settings (device: `/dev/dri/renderD128`).

## Verifying Hardware Transcoding (VA-API)

Direct Play (no transcoding) is the default when your client can handle the source file natively — this is ideal and uses zero CPU/GPU. To confirm VA-API hardware transcoding actually works when needed, you have to force Jellyfin to transcode.

### Force a transcode

In the browser player, click the **gear icon** (bottom-right of player controls) > **Quality** > set to **1.5 Mbps** or lower. This forces Jellyfin to re-encode the video since the source bitrate exceeds the limit. Set it back to **Auto/Max** when done testing.

### Check if VA-API is active

While a forced transcode is running:

1. **Jellyfin Dashboard** (`/web/#/dashboard`) — click the active stream's **info (i) button**. It should show **Transcode** with a reason like "The video's bitrate exceeds the limit". High framerate (100+ fps) indicates hardware encoding.

2. **From the NUC host** — verify the ffmpeg process uses VA-API:

```bash
docker top jellyfin | grep ffmpeg
```

Look for `-hwaccel vaapi` and a VA-API encoder like `hevc_vaapi` or `h264_vaapi` in the command. If you see these, hardware transcoding is working.

3. **Compare power/CPU usage**:
   - Direct Play: minimal CPU, lowest power draw
   - Hardware transcode (VA-API): slight CPU increase (~5W), high transcode fps (100+)
   - Software transcode (no VA-API): high CPU usage, significant power increase (~20W+), low fps (20-40)

### If VA-API is not being used

- Verify the GPU device is visible inside the container: `docker exec jellyfin ls -la /dev/dri/` — should show `renderD128` and `card*`
- Check Jellyfin settings: Dashboard > Playback > Transcoding — **Hardware acceleration** must be set to **Video Acceleration API (VA-API)** with device `/dev/dri/renderD128`, all hardware decoding boxes checked, and hardware encoding enabled
- Verify the jellyfin user has GPU access: `docker exec jellyfin id` — should include group `993` (render) and `44` (video)

## Troubleshooting

### GPU device not found (`/dev/dri/card0: no such file or directory`)

The Intel GPU card device name varies by system. Check what's available:

```bash
ls -la /dev/dri/
```

Update the `devices` section in `docker-compose.yml` to match (e.g., `card1` instead of `card0`). The `renderD128` device is the one actually used for VA-API transcoding; the `card*` device provides additional GPU access.

### `Unable to find group render`

Docker resolves group names from inside the container. If the container image doesn't define a `render` group, the lookup fails. Fix by using the numeric GID instead:

```bash
# Find the host GID for render
getent group render
# e.g. render:x:993:dragosnuc
```

Then in `docker-compose.yml`, use `"993"` instead of `"render"` in `group_add`.
