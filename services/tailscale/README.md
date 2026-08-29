# Tailscale

Mesh VPN providing secure remote access across all homelab nodes.

## Known Issues

### MagicDNS stops forwarding to AdGuard after network change (macOS)

MagicDNS (100.100.100.100) may stop forwarding DNS queries to the configured global nameserver (AdGuard) after switching WiFi networks or waking from sleep. Queries resolve via a fallback path instead, bypassing AdGuard entirely — `.lan` names stop resolving and ad blocking stops working. This is a known Tailscale bug affecting v1.94 through at least v1.102.3 (see [tailscale/tailscale#19199](https://github.com/tailscale/tailscale/issues/19199), [#19216](https://github.com/tailscale/tailscale/issues/19216)).

**Diagnose:**

```bash
scutil --dns | head -12                        # broken: Tailscale resolver only "Supplemental", default is router/1.1.1.1
dig +short adguard.lan @100.100.100.100        # broken: empty/NXDOMAIN
dig +short doubleclick.net @100.100.100.100    # broken: real IP instead of 0.0.0.0
```

**Workarounds, in escalating order:**

1. Flush macOS DNS cache: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`
2. Restart Tailscale — quit and relaunch the app (the macOS GUI app runs as a network extension; there is no `tailscaled` process to kill).
3. If the broken state survives app restarts and `tailscale set --accept-dns=false/true` toggles: check `systemextensionsctl list` for stale Tailscale network extensions in state "terminated waiting to uninstall on reboot" (left behind by app updates). These corrupt the network-extension DNS state — **reboot the Mac** to clear them. (This was the fix in Aug 2026: four stale extensions had accumulated across updates.)

**Mitigation:** the tailnet has a split DNS route `lan → AdGuard` in the admin console (DNS → Add nameserver → Custom → Restrict to domain `lan`), in addition to AdGuard as the global override nameserver. Domain-scoped resolvers survive this bug, so `*.lan` names keep resolving even while the global override (ad blocking) is broken.
