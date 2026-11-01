# Security

Hardening measures in place across the homelab, with how to check each one. Add a row when a change affects security; keep secrets, public IPs and known-open gaps out of this file (it is public).

## Network edge

| Measure | Scope | Since | Verify |
|---|---|---|---|
| No inbound internet path: ISP carrier-grade NAT on the WAN, IPv6 disabled | Router | 2026-11-01 | Router → Network Map → Internet: WAN IP in `100.64.0.0/10`; IPv6 connection type `Disabled` |
| No port forwarding, DMZ, Open NAT or UPnP/NAT-PMP | Router | 2026-11-01 | Router → WAN → Virtual Server, DMZ, Internet Connection; Game → Open NAT |
| Router admin, SSH and AiCloud not reachable from WAN; firmware current | Router | 2026-11-01 | Router → Administration → System; AiCloud 2.0 |

If the ISP ever assigns a public IPv4 or IPv6 is enabled, re-check the above and scan from outside the network.

## Remote access (Tailscale)

| Measure | Scope | Since | Verify |
|---|---|---|---|
| Tailscale 1.104.4 or later (fixes TS-2026-013 to 017) | All nodes and clients | 2026-11-01 (`3ccc50f`) | `docker exec tailscale tailscale version`; admin console → Machines |
| FileBrowser and Samba accept tailnet clients only | `dragospi5` | `ea5563b`, `2f55dc6` | `docker ps` shows FileBrowser on the Tailscale IP; `sudo testparm -s \| grep 'hosts allow'` |
| Role tags instead of one shared server tag: `tag:dns` (pi-infra), `tag:nas` (dragospi5), `tag:media` (nuc), `tag:photos` (M1). Servers reach each other only for DNS | Tailnet policy | 2026-11-01 | Admin console → Machines shows the role tag on each server |
| Family reaches only Samba, FileBrowser, Seerr, Jellyfin and DNS; no SSH, arr apps or admin pages. Policy tests reject any edit that breaks this | Tailnet policy | 2026-11-01 | Admin console → Access controls saves without test failures |
| Servers joined with single-use, tagged, non-ephemeral keys (1-day expiry); no auth key left in any `.env`; tagged logins never expire | `nuc`, `dragospi5`, `pi-infra` | 2026-11-01 | `docker exec tailscale env \| grep TS_AUTHKEY` → empty; admin console → Keys is empty and Machines shows no Ephemeral badge |
| No exit node or Tailscale SSH on servers: `TS_EXTRA_ARGS=--reset`, so any flag not listed is off after a restart | `nuc`, `dragospi5`, `pi-infra` | 2026-11-01 | `docker exec tailscale tailscale debug prefs \| grep -A2 -E '"RunSSH"\|"AdvertiseRoutes"'` → `false`, `null` |
| New devices need manual approval before they join (Device approval) | Tailnet | 2026-11-01 | Admin console → Settings → Device management |

## SSH

| Measure | Scope | Since | Verify |
|---|---|---|---|
| Key-only login, no root login (`/etc/ssh/sshd_config.d/01-hardening.conf`); the setup scripts write it on new installs once a key is in `authorized_keys` | `nuc`, `dragospi5`, `pi-infra` | 2026-11-01 | `sudo sshd -T \| grep -E '^(passwordauthentication\|permitrootlogin\|authenticationmethods) '` → `no`, `no`, `publickey` |
| NAS user accounts have no login shell (`/usr/sbin/nologin`) | `dragospi5` | 2026-11-01 | `getent passwd <user> \| cut -d: -f7` → `/usr/sbin/nologin` |

The drop-in is named `01-` because sshd keeps the first value it reads; a later file such as Ubuntu's `50-cloud-init.conf` cannot re-enable passwords. Console login (monitor and keyboard) still uses the account password.

```
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
```

## Applications

| Measure | Scope | Since | Verify |
|---|---|---|---|
| Sonarr, Radarr, Prowlarr require login for every address (`AuthenticationRequired=Enabled`) | arr-stack | 2026-11-01 | `grep -h AuthenticationRequired services/arr-stack/data/{sonarr,radarr,prowlarr}/config.xml` |
| qBittorrent: no auth bypass for localhost or subnets; UPnP off | arr-stack | 2026-11-01 | Tools → Options → Web UI and Connection |
| Images pinned to exact versions at or above current security fixes | All services | `3ccc50f`, `ccee318` | `grep -hn 'image:' services/*/docker-compose.yml` |
| Samba: SMB3.11 minimum, encryption and signing mandatory | `dragospi5` | `2f55dc6` | `sudo testparm -s \| grep -E 'min protocol\|smb encrypt\|signing'` |
| FileBrowser admin password changed from the `admin/admin` default | `dragospi5` | 2026-11-01 | Logging in as `admin` / `admin` fails |

## Repository

| Measure | Scope | Since | Verify |
|---|---|---|---|
| `.env`, `.env.*`, `data/` and app databases are git-ignored | All services | `aa172f3`, `e0acbe4` | `git check-ignore -v services/<svc>/data/x services/<svc>/.env` |
| gitleaks `pre-commit` and `pre-push` hooks with a Tailscale key rule (`.githooks/`, `.gitleaks.toml`); the push scan also catches `--no-verify` commits; both fail if gitleaks is missing | Every clone (`make setup` / `make hooks`) | `e0acbe4` | `git config core.hooksPath` → `.githooks`; `gitleaks version` |
