# CLAUDE.md

Modular homelab running Docker containers across multiple hosts. Each service is self-contained under `services/<name>/` with its own `docker-compose.yml`, `.env.example`, `.gitignore`, and `data/` directory.

## Commands

```bash
make setup              # First-time: creates 'homelab' network + copies .env.example -> .env
make up / make down     # Start/stop all services
make up-<svc>           # Start one service (e.g., make up-jellyfin)
make logs-<svc>         # Tail logs
make status             # Show running containers
```

## Architecture

- **Makefile** auto-discovers services via `services/*/` — no changes needed when adding a service.
- All services share an external Docker network `homelab`. Exception: Tailscale uses `network_mode: host`.
- `.env` files (git-ignored) for config; defaults inline via `${VAR:-default}`.
- Persistent data in `data/` per service (git-ignored, `data/.gitkeep` tracked).
- Prefers LinuxServer.io images (`lscr.io/linuxserver/*`) with `PUID`/`PGID`.
- Compose conventions: `restart: unless-stopped`, `no-new-privileges`, JSON-file logging with rotation, healthchecks, resource limits, `com.homelab.*` labels.

## Adding a Service

1. Create `services/<name>/` with `docker-compose.yml`, `.env.example`, `.gitignore`, `data/.gitkeep`
2. Join the `homelab` external network
3. `make setup && make up-<name>`

## Hardware Inventory

| Node | Hostname | IP | Specs |
|------|----------|----|-------|
| Intel NUC 8 Pro | `nuc` | `static ip 3` | i3-8145U, 16GB RAM, 512GB SSD, VA-API transcoding |
| Raspberry Pi 5 | `dragospi5` | `static ip 2` | 4GB RAM, Penta SATA HAT, 8TB HDD + 1TB SSD, SD boot |
| Raspberry Pi 3B+ | `pi-infra` | `static ip 1` | 1GB RAM |
| Raspberry Pi 3B+ | — | — | 1GB RAM (backup) |
| Mac Mini 2018 | — | — | i5, 8GB RAM (future/on-demand, Immich candidate) |
| MacBook Pro M1 | — | — | 32GB RAM (on-demand compute, dev/testing) |
| 2TB Samsung portable SSD | — | — | Photo backup |

## Node Allocation

| Node | Hostname | Services |
|------|----------|----------|
| RPi 3B+ | `pi-infra` | AdGuard Home, Tailscale |
| Intel NUC | `nuc` | Jellyfin, Tailscale |
| RPi 5 | `dragospi5` | NAS (Samba/NFS), Filebrowser, Tailscale, *arr stack |

## Coding Guidelines

1. **Think first** — State assumptions explicitly. If ambiguous, present interpretations and ask — don't pick silently. Push back if a simpler approach exists.
2. **Surgical edits** — Only change what the task requires. Match existing style. Remove only orphans YOUR changes created. Mention (don't delete) unrelated dead code. Litmus test: every changed line traces to the request.
3. **Goal-driven** — Transform tasks into verifiable goals ("fix bug" → "write reproducing test, then make it pass"). For multi-step work, state a brief plan with a verify check per step.

## Subagent Strategy
- Use Explore subagent for broad codebase searches and dependency mapping
- Use general-purpose subagent for multi-step research
- Delegate independent tasks to parallel subagents to keep main context clean

## Response Style - IMPORTANT!
- No filler words or hedging ("just", "simply", "I think", "maybe") or pleasantries (sure/certainly/of course/happy to)
- Keep articles (a/an/the) and full sentences
- Professional but tight — say it in fewer words without sacrificing clarity
- Lead with the answer or action, not the reasoning
- Skip preamble and unnecessary transitions
- Don't restate what the user said