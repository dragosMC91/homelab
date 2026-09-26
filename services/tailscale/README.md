# Tailscale

Mesh VPN providing secure remote access across all homelab nodes.

## MacBook Pro M1 setup (headless server, Homebrew tailscaled)

The M1 sits in the rack and is only reached over the tailnet (SSH + Screen Sharing). It runs the open-source `tailscaled` from Homebrew as a root launchd daemon, so it is reachable after a reboot without anyone logging in. Tailscale's DNS programming is disabled and system DNS stays on plain DHCP — the node has no need for AdGuard over the tunnel, and any DNS dependency on the tunnel breaks boot (see Known Issues).

```bash
brew install tailscale
sudo brew services start tailscale                      # /Library/LaunchDaemons/sh.brew.tailscale.plist, state in /Library/Tailscale/
sudo tailscale up --accept-dns=false --ssh --advertise-tags=tag:server   # browser auth; --ssh = Tailscale SSH (identity auth, no keys)
networksetup -setdnsservers AX88179B Empty              # DHCP DNS on the USB Ethernet service (Wi-Fi is fallback only)
```

macOS side:

- System Settings → General → Sharing → enable Remote Login and Screen Sharing. Connect via the tailnet hostname or IP.
- System Settings → Privacy & Security → "Allow accessories to connect" → **Always**. Any other value blocks USB devices plugged in while locked or before login (`log show` says "device will not be registered for matching"), so the USB Ethernet adapter never gets an interface after a reboot.
- Network: USB Ethernet adapter (service `AX88179B`, static IP, /24 mask) first in service order; Wi-Fi may stay on as fallback. Service names: `networksetup -listnetworkserviceorder`.

**Operating notes:**

- Changing one setting: `sudo tailscale set --<flag>`. `tailscale up` refuses unless every non-default flag is restated; it prints the full command to copy.
- Rebooting: with FileVault on, a plain restart stops at the pre-boot unlock screen — no OS, no network, no tailscaled. Use `sudo fdesetup authrestart` to reboot straight into macOS once.
- Verify after reboot/upgrade: `tailscale status` (health check section must be empty), `tailscale version --daemon` (Client and Daemon match), `tailscale debug prefs | grep CorpDNS` (`false`).
- No menu-bar UI — use the `tailscale` CLI. Updates via `brew upgrade`.

## Pointing a client Mac's DNS at AdGuard over the tailnet

For a Mac used as a client (not the headless M1 above) that should get `.lan` names and ad blocking, bypass Tailscale's DNS programming entirely — it is unreliable on macOS (see Known Issues) — and set the resolver manually:

```bash
sudo tailscale set --accept-dns=false
networksetup -setdnsservers Wi-Fi 100.68.66.22
```

**Caveats (issues hit in Aug 2026 and their fixes):**

- **System DNS now depends on the tunnel.** `100.68.66.22` is a tailnet IP; stop tailscaled and all DNS dies. Revert/restore:

```bash
networksetup -setdnsservers Wi-Fi Empty          # back to DHCP DNS (tailscaled stopped, captive-portal Wi-Fi)
networksetup -setdnsservers Wi-Fi 100.68.66.22   # restore AdGuard DNS once the tunnel is up
  ```

- **MagicDNS `*.ts.net` names don't resolve** (AdGuard doesn't know them) — use the `.lan` rewrites or tailnet IPs.
- **Ad blocking looks broken although DNS is fine** (test pages score low, e.g. adblock.turtlecute.org at 65% instead of 90%+): the browser is bypassing system DNS. Verify DNS first — `dig +short doubleclick.net` must return `0.0.0.0`. If it does, fix the browser: restart it / clear its DNS cache (Chrome: `chrome://net-internals/#dns`), disable DNS-over-HTTPS ("Secure DNS" in Chrome, DoH in Firefox), and note iCloud Private Relay bypasses AdGuard in Safari by design.

## Known Issues

### GUI app (network extension) DNS breaks after sleep/network change (macOS)

The GUI app's network extension stops applying the tailnet DNS config (global nameserver + split DNS routes) after switching WiFi or waking from sleep: MagicDNS (100.100.100.100) forwards to system DNS instead of AdGuard, and `scutil --dns` shows the Tailscale resolver as "Supplemental" only while the default resolver falls back to router/1.1.1.1. `.lan` names stop resolving and ad blocking stops working. Known bug, v1.94 through at least v1.102.3 (see [tailscale/tailscale#19199](https://github.com/tailscale/tailscale/issues/19199), [#19216](https://github.com/tailscale/tailscale/issues/19216)). App restarts, `--accept-dns` toggles, and DNS cache flushes do not recover it; a reboot does, but it re-breaks on the next sleep/network change. This is why the MacBook was migrated to the Homebrew setup above (Aug 2026).

**Diagnose:**

```bash
scutil --dns | head -12                        # broken: Tailscale resolver only "Supplemental", default is router/1.1.1.1
dig +short adguard.lan @100.100.100.100        # broken: empty/NXDOMAIN
dig +short doubleclick.net @100.100.100.100    # broken: real IP instead of 0.0.0.0
```

### Deleting the GUI app orphans its network extension

Trashing `Tailscale.app` does NOT remove its system extension — it keeps running from `/Library/SystemExtensions` (visible in `ps aux | grep network-extension` and `systemextensionsctl list`), intercepting DNS to 100.100.100.100 in whatever broken/logged-out state it was in, and fights any replacement Tailscale install. `systemextensionsctl uninstall` is blocked by SIP. Remove it via System Settings → General → Login Items & Extensions → Network Extensions → disable Tailscale, delete any leftover entry under System Settings → VPN, then reboot to finalize the uninstall. (Proper uninstall order: delete the app via Finder while it's still installed — macOS then prompts to remove the extension.)

### Open-source tailscaled: MagicDNS quad100 gives wrong answers (macOS)

With Homebrew `tailscaled` and `--accept-dns=true`, UDP queries to 100.100.100.100 are answered via the host's system DNS instead of the configured tailnet resolvers (`tailscale dns query <name>` answers correctly; `dig @100.100.100.100` does not). Don't rely on quad100 — keep `--accept-dns=false` and leave DNS to DHCP as in the setup above.

### Open-source tailscaled: logged out after reboot, system DNS dead (macOS)

Symptom after a reboot: `tailscale status` shows the node `offline` with health check "You are logged out ... register request ... context deadline exceeded"; `dig <anything>` times out although `dig @1.1.1.1` works; `/etc/resolv.conf` lists only `100.100.100.100`. Cause: `--accept-dns=true` was in effect at boot, tailscaled pointed the system resolver at quad100, then could not resolve `controlplane.tailscale.com` through its own dead resolver — so it never logs in and quad100 never answers. Fix (Sep 2026):

```bash
sudo tailscale set --accept-dns=false          # tailscaled restores the resolver
dig +short controlplane.tailscale.com          # must answer now
sudo tailscale up <full flag set it prints>    # reconnects with the existing node key, no browser auth
```

Prevention: never re-enable `--accept-dns` on this node; `tailscale up --reset` would.

### Homebrew tailscaled: `brew cleanup` fails with "Permission denied" on old keg (macOS)

`sudo brew services start tailscale` runs Homebrew as root and leaves root-owned files in the tailscale keg, so the next `brew upgrade`/`brew cleanup` fails removing the old version. File ownership is independent of the daemon — launchd still runs `tailscaled` as root. Fix (Sep 2026):

```bash
sudo chown -R "$(whoami):admin" /opt/homebrew/Cellar/tailscale /opt/homebrew/opt/tailscale
brew cleanup tailscale
sudo brew services restart tailscale   # pick up the upgraded binary
tailscale version --daemon             # Client and Daemon versions must match
```

Expect this to recur after each `sudo brew services` invocation.

## Tailnet DNS config (admin console)

- Global nameserver: `100.68.66.22` (AdGuard) with "Override DNS servers" ON.
- Split DNS route: `lan → 100.68.66.22` (DNS → Add nameserver → Custom → Restrict to domain `lan`) — keeps `*.lan` resolving on devices where the global override breaks.
