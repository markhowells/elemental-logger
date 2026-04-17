# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Raspberry Pi setup for a marine vessel. It configures the Pi as a WiFi access point and runs a Docker stack with:

- **SignalK** (port 3000) — reads NMEA 2000 data from a CAN bus (`can0` at 250 kbps) and provides the vessel data API
- **InfluxDB** (port 8086) — time-series storage for vessel data, fed by SignalK via a custom plugin (`signalk-to-influxdb2`)
- **Portainer** (port 9000) — Docker management UI

## Setup workflow

All secrets and site-specific values live in `marine.conf`. The file ships with `changeme` placeholders that `setup.sh` explicitly rejects.

```bash
# 1. Fill in marine.conf (all changeme values must be replaced)
# 2. Run as root:
sudo ./setup.sh
```

`setup.sh` does everything in order: installs Docker + hostapd + dnsmasq, configures the WiFi AP (`wlan0` static IP `10.42.0.1/24`), builds the SignalK image, installs and starts Portainer, bootstraps the Portainer admin user via API, then starts the marine stack.

## Templated files

Several files are generated from templates by `setup.sh` — **never edit the generated files directly**:

| Template | Generated |
|---|---|
| `docker-compose.yml.template` | `docker-compose.yml` |
| `config/signalk/settings.json.template` | `config/signalk/settings.json` |
| `config/signalk/plugin-config-data/signalk-to-influxdb2.json.template` | `config/signalk/plugin-config-data/signalk-to-influxdb2.json` |
| `systemd/portainer.service` (contains `SCRIPT_DIR_PLACEHOLDER`) | `/etc/systemd/system/portainer.service` |
| `systemd/marine-stack.service` (contains `SCRIPT_DIR_PLACEHOLDER`) | `/etc/systemd/system/marine-stack.service` |

Placeholders use the pattern `THING_PLACEHOLDER`.

## SignalK Docker image

The custom image (`marine-signalk:latest`) is built from `Dockerfile`. It extends `signalk/signalk-server:latest`, installs a fork of the `signalk-to-influxdb2` plugin from GitHub, and seeds config files on first run via `docker-entrypoint.sh`.

The entrypoint runs a restart watchdog loop — it starts `signalk-server`, waits up to 90s for the HTTP endpoint to respond, then health-checks every 5s and restarts if SignalK stops responding. D-Bus and Avahi are started once (not per-restart) to avoid 40s delays.

After changing `Dockerfile`:
```bash
docker build -t marine-signalk:latest .
sudo systemctl restart marine-stack
```

## Day-to-day operations

```bash
# View logs
docker logs signalk
docker logs influxdb

# Restart the full stack
sudo systemctl restart marine-stack

# Check service status
sudo systemctl status marine-stack portainer

# Bring stack up/down manually
docker compose up -d
docker compose down
```

## Network layout

- `wlan0` — WiFi AP at `10.42.0.1/24`, managed by `hostapd` + `dnsmasq`; explicitly unmanaged from NetworkManager
- `can0` — NMEA 2000 CAN bus at 250 kbps, configured via `systemd-networkd` (`config/can0.network`)
- SignalK uses `network_mode: host` so it can reach `can0` directly
- InfluxDB is on the `marine_net` bridge network
