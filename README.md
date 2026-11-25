# Elemental logger (Marine Pi)

A Raspberry Pi for a sailing vessel: reads NMEA 2000 from a CAN bus, serves it with **SignalK**, logs history to
**InfluxDB**, manages containers with **Portainer**, serves a landing page/reverse proxy with **Caddy**, and
broadcasts its own Wi-Fi access point (`10.42.0.1`) so phones and tablets work without a router.

The Pi is **offline at sea** and online only occasionally, so releases are *pulled* by the Pi when it can reach
the Internet; nothing is ever pushed to it. See [docs/config-model.md](docs/config-model.md) for how
configuration, secrets and updates fit together and [docs/boat-checklist.md](docs/boat-checklist.md) for what to
do before and after a trip.

## Services

| Service | URL on the boat Wi-Fi |
|---|---|
| Landing page | `http://elemental.internal/` (or `http://10.42.0.1/`) |
| SignalK | `http://signalk.elemental.internal/` (or `:3000`) |
| InfluxDB | `http://influx.elemental.internal/` (or `:8086`) |
| Portainer | `http://portainer.elemental.internal/` (or `:9000`) |

## Install (needs Internet once)

```bash
# On the Pi, from a checkout of this repo or an extracted release bundle:
sudo ./deploy/install.sh      # first run creates /etc/marine/marine.env from marine.env.example and stops
sudo nano /etc/marine/marine.env   # replace every 'changeme'; org/bucket must match any EXISTING InfluxDB
sudo ./deploy/install.sh      # installs host packages, units, renders config, starts everything
sudo marine-doctor            # check it
```

Secrets live only in `/etc/marine/marine.env` (mode 0600). They are never committed and never baked into images.

## Day to day

```bash
sudo marine-doctor            # health + drift report (read-only)
sudo marine-apply             # re-render config from the release and apply it
sudo marine-update --check    # is there a newer release? (quiet when offline)
docker logs signalk | influxdb | caddy | portainer
```

## Repo layout

```
images/signalk/    Dockerfile, entrypoint, CAN helper scripts, plugin.version (pinned plugin + base image)
config/            templates only (SignalK, hostapd, dnsmasq, Caddyfile, landing page, can0.network)
deploy/            compose files, images.env (pins), marine-apply/-doctor/-update, install.sh, systemd units
tools/             canswitch.sh (vcan bench switch), smoke-test.sh (CI end-to-end), experimental/
tests/run.sh       unit tests for the renderer, settings merge and updater (no Docker needed)
.github/workflows  ci (lint, tests, build, smoke), release (bundle + Pages feed), plugin-sync (fork vs upstream)
```

## Development

```bash
tests/run.sh                                   # fast, no Docker
set -a; . images/signalk/plugin.version; set +a
docker build -f images/signalk/Dockerfile --build-arg SIGNALK_BASE --build-arg PLUGIN_REPO --build-arg PLUGIN_REF \
    -t elemental-signalk:dev images/signalk
SIGNALK_IMAGE=elemental-signalk:dev tools/smoke-test.sh   # vcan -> SignalK -> InfluxDB (needs Docker + sudo)
```
