# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Raspberry Pi setup for a marine vessel (public repo `markhowells/elemental-logger`). It configures the Pi as a
WiFi access point and runs a Docker stack:

- **SignalK** (port 3000) — reads NMEA 2000 from a CAN bus (`can0`, 250 kbps) and provides the vessel data API
- **InfluxDB** (8086) — time-series store, fed by SignalK via a fork of `signalk-to-influxdb2`
- **Caddy** (80/443) — landing page + reverse proxy (`signalk.|influx.|portainer.elemental.internal`)
- **Portainer** (9000) — Docker management UI

The Pi is **offline when deployed** and has no RTC. It pulls releases when it happens to be online; CI never
connects to it. Read `docs/config-model.md` before changing anything about config, secrets or deployment.

## Hard rules

* **Secrets never go in git or in an image.** They live only in `/etc/marine/marine.env` on the Pi
  (template: `marine.env.example`). The repo and Docker Hub images are public. Vessel name/MMSI are secrets too.
* **Never edit generated/rendered files** (`/var/lib/marine/rendered/*`, or config inside the SignalK volume) —
  they are overwritten. Edit `config/*.template` / `marine.env` and run `marine-apply`.
* **Never rename the compose project or volumes.** `name: pi` and the explicit `pi_*` volume names in
  `deploy/docker-compose.yml` / `deploy/portainer.yml` keep the existing data attached; changing them silently
  creates empty volumes (looks like total data loss).
* **Never recreate the InfluxDB volume.** On an existing volume the `DOCKER_INFLUXDB_INIT_*` env is ignored.
* Do not change image pins (`deploy/images.env`, `images/signalk/plugin.version`) as a side effect; bump on purpose.
* Placeholders use `THING_PLACEHOLDER` and resolve to variable `THING` (`deploy/lib/render.py`).

## Layout

```
images/signalk/   Dockerfile (no config baked in), docker-entrypoint.sh, bin/ (analyzer, merge-settings), plugin.version
config/           templates → rendered by marine-apply
deploy/           docker-compose.yml, portainer.yml, images.env, marine-apply/-doctor/-update, install.sh, systemd/, lib/render.py
tools/            canswitch.sh, smoke-test.sh, experimental/ (unused canSocket-socketcan.js)
tests/run.sh      unit tests — run after any change to deploy/ or config/
.github/workflows ci, build-image (reusable), release, plugin-sync
```

## Config flow

`marine.env` + templates → `deploy/lib/render.py` → `/var/lib/marine/rendered/` → bind-mounted read-only into
containers. The SignalK entrypoint applies the plugin config on every start and merges only the managed keys of
`settings.json` (`images/signalk/bin/merge-settings.js`); SignalK-owned keys and `security.json` are preserved.

## Operations (on the Pi)

```bash
sudo marine-doctor          # read-only health/drift report
sudo marine-apply           # render + apply
sudo marine-update --check  # release feed (quiet when offline)
sudo systemctl restart marine-stack
docker logs signalk | influxdb | caddy
```

## Network layout

- `wlan0` — AP at `10.42.0.1/24` (`hostapd` + `dnsmasq`, unmanaged by NetworkManager); dnsmasq wildcard `*.elemental.internal`
- `can0` — `systemd-networkd` (`config/can0.network`); SignalK uses `network_mode: host`, as does Caddy
- InfluxDB is on the `pi_marine_net` bridge network, published on 8086

## Testing

`tests/run.sh` (no Docker). `tools/smoke-test.sh` runs vcan → SignalK → InfluxDB end to end (needs Docker + sudo; CI runs it).
