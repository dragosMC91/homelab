# Tailscale

Mesh VPN providing secure remote access across all homelab nodes.

## Known Issues

### MagicDNS stops forwarding to AdGuard after network change (macOS)

MagicDNS (100.100.100.100) may stop forwarding DNS queries to the configured global nameserver (AdGuard) after switching WiFi networks or waking from sleep. Queries resolve via a fallback path instead, bypassing AdGuard entirely. This is a known Tailscale bug affecting v1.94–1.96+ (see [tailscale/tailscale#19199](https://github.com/tailscale/tailscale/issues/19199), [#19216](https://github.com/tailscale/tailscale/issues/19216)).

**Workaround — flush macOS DNS cache:**

```bash
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```

If that's not enough, restart Tailscale (`sudo killall tailscaled; open -a Tailscale`).
