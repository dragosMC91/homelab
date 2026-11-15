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
| qBittorrent, Prowlarr, Radarr, Sonarr, Bazarr and the AdGuard admin pages publish on the Tailscale IP only; compose refuses to start while the IP is unset. Uptime Kuma's compose file does the same | `dragospi5`, `pi-infra` | 2026-11-15 (`a8e43eb`) | `docker ps --format '{{.Names}} {{.Ports}}'` lists only the Tailscale IP for those ports |
| Traffic to a node's Tailscale IP is dropped unless it arrives on `tailscale0` (`DOCKER-USER` rule, re-added by a `docker.service` drop-in) | `dragospi5`, `nuc`, `pi-infra` | 2026-11-15 | `sudo iptables -S DOCKER-USER` lists the rule; the routed test in the setup steps below times out |
| Role tags instead of one shared server tag: `tag:dns` (pi-infra), `tag:nas` (dragospi5), `tag:media` (nuc), `tag:photos` (M1). Servers reach each other only for DNS | Tailnet policy | 2026-11-01 | Admin console → Machines shows the role tag on each server |
| Family reaches only Samba, FileBrowser, Seerr, Jellyfin and DNS; no SSH, arr apps or admin pages. Policy tests reject any edit that breaks this | Tailnet policy | 2026-11-01 | Admin console → Access controls saves without test failures |
| Servers joined with single-use, tagged, non-ephemeral keys (1-day expiry); no auth key left in any `.env`; tagged logins never expire | `nuc`, `dragospi5`, `pi-infra` | 2026-11-01 | `docker exec tailscale env \| grep TS_AUTHKEY` → empty; admin console → Keys is empty and Machines shows no Ephemeral badge |
| No exit node or Tailscale SSH on servers: `TS_EXTRA_ARGS=--reset`, so any flag not listed is off after a restart | `nuc`, `dragospi5`, `pi-infra` | 2026-11-01 | `docker exec tailscale tailscale debug prefs \| grep -A2 -E '"RunSSH"\|"AdvertiseRoutes"'` → `false`, `null` |
| New devices need manual approval before they join (Device approval) | Tailnet | 2026-11-01 | Admin console → Settings → Device management |

### Tailscale-only web UIs: setup per node

Run on each node that publishes a web UI on its Tailscale IP. Connect over the LAN IP. Every block is one command.

1. Let containers bind the Tailscale IP before `tailscale0` exists at boot:

   ```bash
   echo 'net.ipv4.ip_nonlocal_bind=1' | sudo tee /etc/sysctl.d/99-nonlocal-bind.conf && sudo sysctl --system
   ```

2. Read the node's Tailscale IP. It must print a `100.x` address before you go on:

   ```bash
   TSIP=$(docker exec tailscale tailscale ip -4); echo $TSIP
   ```

3. Put that address in the service's `.env` (`TAILSCALE_IP=` for arr-stack, Uptime Kuma and FileBrowser; `ADGUARD_BIND_IP=` for AdGuard), then recreate the service:

   ```bash
   make pull-<svc> && make up-<svc>
   ```

4. Drop connections aimed at the Tailscale IP unless they arrive through Tailscale. `--ctdir ORIGINAL` limits the rule to the client's packets; without it the containers' replies are dropped too and tailnet access breaks:

   ```bash
   sudo iptables -I DOCKER-USER ! -i tailscale0 -m conntrack --ctorigdst $TSIP --ctdir ORIGINAL -j DROP
   ```

5. Re-add that rule whenever Docker starts (one line), then reload systemd:

   ```bash
   sudo mkdir -p /etc/systemd/system/docker.service.d && printf '[Service]\nExecStartPost=-/bin/sh -c "iptables -C DOCKER-USER ! -i tailscale0 -m conntrack --ctorigdst %s --ctdir ORIGINAL -j DROP 2>/dev/null || iptables -I DOCKER-USER ! -i tailscale0 -m conntrack --ctorigdst %s --ctdir ORIGINAL -j DROP"\n' $TSIP $TSIP | sudo tee /etc/systemd/system/docker.service.d/10-tailnet-only.conf
   ```

   ```bash
   sudo systemctl daemon-reload
   ```

6. Verify on the node: the moved ports show the `100.x` address, and the rule is listed once.

   ```bash
   docker ps --format '{{.Names}}\t{{.Ports}}'
   ```

   ```bash
   sudo iptables -S DOCKER-USER
   ```

7. Verify from a LAN machine with Tailscale disconnected (macOS shown). The `nc` must time out, and `sudo iptables -L DOCKER-USER -v -n` on the node then shows a packet count above 0 on the rule:

   ```bash
   sudo route -n add -host <node-tailscale-ip> <node-lan-ip>
   nc -zv -G 3 <node-tailscale-ip> <port>
   sudo route -n delete -host <node-tailscale-ip>
   ```

8. Reboot once and repeat step 6. The rule must be back without adding it by hand.

If a node's Tailscale IP changes, update its `.env` values and repeat steps 4 and 5.

If Tailscale is down on a node, reach a web UI through an SSH tunnel to its container: get the address with `docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' sonarr`, run `ssh -L 8989:<container-ip>:8989 <user>@192.168.50.3`, then open `http://localhost:8989`.

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
| Bazarr requires Form login; logged-out page loads get no API key | arr-stack | 2026-11-08 | From a tailnet device: `curl -s http://<pi-tailscale-ip>:6767/ \| grep -c apiKey` → `0`; a private browser window shows the login page |
| qBittorrent: no auth bypass for localhost or subnets; UPnP off | arr-stack | 2026-11-01 | Tools → Options → Web UI and Connection |
| Images pinned to exact versions at or above current security fixes | All services | `3ccc50f`, `ccee318` | `grep -hn 'image:' services/*/docker-compose.yml` |
| Samba: SMB3.11 minimum, encryption and signing mandatory | `dragospi5` | `2f55dc6` | `sudo testparm -s \| grep -E 'min protocol\|smb encrypt\|signing'` |
| FileBrowser admin password changed from the `admin/admin` default | `dragospi5` | 2026-11-01 | Logging in as `admin` / `admin` fails |

## Repository

| Measure | Scope | Since | Verify |
|---|---|---|---|
| `.env`, `.env.*`, `data/` and app databases are git-ignored | All services | `aa172f3`, `e0acbe4` | `git check-ignore -v services/<svc>/data/x services/<svc>/.env` |
| gitleaks `pre-commit` and `pre-push` hooks with a Tailscale key rule (`.githooks/`, `.gitleaks.toml`); the push scan also catches `--no-verify` commits; both fail if gitleaks is missing | Every clone (`make setup` / `make hooks`) | `e0acbe4` | `git config core.hooksPath` → `.githooks`; `gitleaks version` |
