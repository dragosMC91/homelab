# MacBook Pro M1 — Clamshell Server Setup

Running an M1 MacBook Pro in clamshell mode as a home server, with battery-health management via AlDente Pro.

## Contents

- [Hardware](#hardware)
- [Power Management](#power-management)
- [Battery Management](#battery-management)
- [Networking](#networking)
- [Remote Access](#remote-access)

## Hardware

- MacBook Pro M1 (32GB RAM)
- Lid closed, connected to power via a smart plug (used as an external wake switch — see [Waking the Mac](#waking-the-mac))
- USB-C Ethernet adapter for wired networking
- HDMI dummy plug (display emulator) in the HDMI port so macOS behaves as if a monitor is attached — required for Screen Sharing to render at a usable resolution in clamshell mode; without it, Screen Sharing falls back to a tiny virtual display
- No real external display (headless clamshell)

## Power Management

Clamshell operation requires the Mac to stay awake with the lid closed and no real display attached. Expected `pmset` output:

```text
➜  ~ pmset -g
System-wide power settings:
 SleepDisabled        0
Currently in use:
 standby              0
 Sleep On Power Button 1
 SleepServices        0
 hibernatefile        /var/vm/sleepimage
 powernap             0
 networkoversleep     0
 disksleep            0
 sleep                0 (sleep prevented by powerd, screensharingd)
 hibernatemode        0
 ttyskeepawake        1
 displaysleep         0
 tcpkeepalive         1
 lowpowermode         0
 womp                 1
```

Key fields:

- `sleep 0 (sleep prevented by powerd, screensharingd)` — machine does not sleep while Screen Sharing is active
- `displaysleep 0` / `disksleep 0` — disks and display stay awake
- `womp 1` — wake-on-LAN is enabled in software, but see caveat below

### Waking the Mac

Despite `womp 1`, real wake-on-LAN over the USB-C Ethernet adapter does **not** work in practice — sending magic packets with `wakeonlan` and then attempting SSH fails. The reliable wake method is a **power cycle via the smart plug**:

1. Toggle the smart plug off, then back on.
2. Once power is restored, SSH and Screen Sharing become reachable again.

This likely reflects Apple Silicon limitations around waking from deep sleep over a third-party USB-C NIC. The smart plug is effectively the "power button" for this headless machine.

## Battery Management

### Problem

macOS in clamshell mode requires AC power. Without intervention, the battery stays at 100% permanently, degrading long-term battery health.

**AlDente Pro** manages this by controlling SMC charging, holding the battery at a target percentage (e.g. 80%). However, AlDente runs as a user-level app — if the user session isn't fully active (e.g. at the login screen after a reboot), AlDente can't control charging and the battery cycles on/off repeatedly.

### Current approach: manual login + FileVault

An earlier attempt enabled **auto-login** so AlDente would start immediately after boot, avoiding the lock-screen charge cycling. In practice that didn't meaningfully improve things, so the trade-off was reversed in favour of stronger at-rest security:

- **Auto-login**: disabled — a manual login is required after every reboot before AlDente can take over charge control.
- **FileVault**: enabled — full-disk encryption is on, so the SSD is unreadable without the password.

The consequence is that after a power cycle (e.g. smart-plug toggle or reboot), the Mac sits at the login screen until someone logs in. During that window AlDente cannot throttle charging, so the battery may briefly cycle at 100%. This is the accepted cost of keeping FileVault on.

### Security layers

| Layer | Protection |
|-------|------------|
| **FileVault** | Full-disk encryption — data is unreadable without your password, even if the SSD is removed |
| **Manual login** | Account password required at every boot before the session becomes usable |
| **Screen Sharing auth** | Remote access via Screen Sharing requires authentication on every connection |
| **Find My Mac** | Remote lock/wipe if the device is stolen |
| **Activation Lock** | Apple Silicon ties the device to your Apple ID — a thief can't wipe and reuse it |

Enable FileVault if not already on:

```text
System Settings → Privacy & Security → FileVault → Turn On
```

### AlDente Pro configuration

- **Charge limit**: 80%
- **Sailing mode**: enabled (lets the battery drift a few percent below target before recharging, reducing charge cycles)

### Monitoring

Verify AlDente is holding the charge correctly:

```bash
# One-shot battery status
pmset -g batt

# Continuous raw logging (ctrl-c to exit)
pmset -g rawlog
```

Expected output when working correctly:

```text
No AC; Not Charging; 82%; Cap=82: FCC=100; ...
```

Key fields:

- `No AC; Not Charging` — AlDente has paused charging (good)
- `Cap=82` — current capacity percentage
- `Cycles=110/1000` — battery cycle count (lower is better for longevity)

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Battery cycles on/off at lock screen | User session not active, AlDente can't control SMC | Log in manually so the session becomes active |
| Battery stuck at 100% after login | AlDente not running or not configured | Check AlDente is in login items and charge limit is set |
| `pmset -g batt` shows `AC Power` + `Charging` after login | AlDente lost control | Restart AlDente |

## Networking

### Wired adapter

The MacBook uses a USB-C Ethernet adapter for wired connectivity. macOS makes it the primary network service. Wi-Fi is **disabled** to avoid dual-interface issues (stale DHCP leases, split routing, ACL ambiguity).

> The specific adapter in use at the time of writing is an **AX88179B**-based dongle. Any mainstream USB-C Ethernet adapter should work the same way — substitute the service name (shown by `networksetup -listallnetworkservices`) in the commands below.

### DNS resolution failure on Ethernet

**Symptom**: IP pings work (`ping 1.1.1.1` succeeds) but hostname resolution fails (`ping www.google.com` → "Unknown host"). Screen Sharing also breaks.

**Cause**: Tailscale ACL missing a `tag:server` → `tag:server` grant. When the Mac uses `--advertise-tags=tag:server`, it loses its `group:admin` user identity and becomes a tagged device. Without a server-to-server rule, the Mac can't reach other tagged servers — including the AdGuard DNS server running on `pi-infra`.

**Diagnosis**:

```bash
# Confirms DNS is broken
scutil --dns | head -40          # resolver #1 has no nameservers

# Confirms Tailscale can't see the DNS server
tailscale ping 100.68.66.22      # "no matching peer"
tailscale status                 # homelab/nuc/pi-nas missing from peer list
```

**Fix**: add a server-to-server grant in the Tailscale admin console ACL:

```json
{
    "src": ["tag:server"],
    "dst": ["tag:server"],
    "ip":  ["*"]
}
```

Also set DNS on the Ethernet adapter as a belt-and-suspenders measure. Replace the service name with whatever `networksetup -listallnetworkservices` reports for your adapter:

```bash
networksetup -setdnsservers "AX88179B" 100.68.66.22
```

**Historical note — why Wi-Fi initially appeared to work**: during the original diagnosis, Wi-Fi was still enabled and resolved fine while Ethernet was broken. That was likely a stale Tailscale session cached from when the Mac had been authenticated as a personal `group:admin` device (without `--advertise-tags`). A fresh connection on Ethernet forced ACL re-evaluation, exposing the missing grant. Wi-Fi is now disabled, so this path is closed off entirely.

## Remote Access

Since the MacBook runs headless in clamshell mode, all management is remote:

- **Screen Sharing (VNC)** — System Settings → General → Sharing → Screen Sharing → On
- **SSH** — System Settings → General → Sharing → Remote Login → On
- **Tailscale** — accessible from anywhere on the tailnet (see [tailscale service](../services/tailscale/))
