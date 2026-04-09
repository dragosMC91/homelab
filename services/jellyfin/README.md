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

## Step 4 — Deploy Jellyfin

On the NUC:

```bash
cd ~/homelab
cp services/jellyfin/.env.example services/jellyfin/.env
make up-jellyfin
```

Open <http://192.168.55.111:8096> to run the Jellyfin setup wizard. In the wizard, enable **VA-API hardware transcoding** under Playback settings (device: `/dev/dri/renderD128`).
