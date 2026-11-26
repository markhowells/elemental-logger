# Config model

One rule: **the release is the source of truth for configuration, and the Pi re-applies it every time.**
The only thing that lives on the Pi and nowhere else is `/etc/marine/marine.env` (secrets and per-vessel values).

```
 git repo ──CI──> release bundle (templates + scripts + images.env pinned by digest)
                      │  marine-update (when the Pi is online)
                      ▼
 /opt/marine/releases/<ver>  +  /etc/marine/marine.env
                      │  marine-apply  (deploy/lib/render.py)
                      ▼
 /var/lib/marine/rendered/  ──mounted read-only──>  containers      host files (/etc/hostapd, dnsmasq, systemd)
```

## Managed vs preserved

| Thing | Class | How it is applied |
|---|---|---|
| `signalk-to-influxdb2.json` (plugin config) | **managed** | Overwritten on every SignalK start from `/marine-config`. A differing live copy logs `DRIFT:` first. |
| `settings.json` managed keys: `vessel.name`, `vessel.mmsi`, `pipedProviders`, `port`, `sslport`, `security.strategy`, `security.allow_readonly` | **managed keys** | `merge-settings` sets these on every start. A managed key absent from the template is **removed** from the live file. |
| rest of `settings.json` (`interfaces`, `resourcesApi`, `courseApi`, UI changes) | preserved | SignalK rewrites these at runtime; never overwritten. |
| `security.json`, users, tokens, KIP history, resources | preserved | Live in the `pi_signalk_data` volume. |
| compose files, hostapd, dnsmasq, Caddyfile, landing page, systemd units, `can0.network` | **managed** | Rendered/installed by `marine-apply`; changed ones restart only the affected service. |
| image references | **pinned** | `deploy/images.env` (digests). Bump deliberately; a release rewrites `SIGNALK_IMAGE`. |
| InfluxDB data, Portainer data | data | Volumes `pi_influxdb_*`, `pi_portainer_data`. Never touched by apply. |

Editing a managed file by hand (in the volume or in `/var/lib/marine/rendered`) is pointless: it is overwritten.
Change the template (or `marine.env`) and run `marine-apply`.

## Why project and volume names are pinned

The original install ran Compose from a directory called `pi`, so the volumes are `pi_signalk_data`,
`pi_influxdb_data`, `pi_influxdb_config`, `pi_portainer_data` and the network `pi_marine_net`. Compose derives
those names from the project (directory) name, so moving the compose file would silently create **new, empty**
volumes that look exactly like lost data. `deploy/docker-compose.yml` and `deploy/portainer.yml` therefore set
`name: pi` and explicit `name:` on every volume. Do not remove them.

## `marine.env`

See `marine.env.example` for every variable. Notable:

* `INFLUXDB_ORG` / `INFLUXDB_BUCKET` are where **SignalK writes** (rendered into the plugin config). On an existing
  database they must match what exists. The `DOCKER_INFLUXDB_INIT_*` values in compose only matter for the very
  first start of an empty volume; on an existing volume InfluxDB skips setup and cannot change org/bucket/token.
* Live system today: org `Elemental`, bucket `sailing_data`, measurement `instruments`.
  (The old `marine` org / `signalk` bucket holds only April 2026 test data.)
* `INFLUX_RESOLUTION_MS` and `INFLUX_IGNORED_PATHS` control write volume. Defaults reproduce today's behaviour
  (everything, every update, ~2,500 points/s of which ~90% is 40 Hz `electrical.switches.bank.*` state).
  Recommended: `INFLUX_RESOLUTION_MS=1000`, `INFLUX_IGNORED_PATHS=electrical.switches.bank.*`.
* `SIGNALK_ALLOW_READONLY` defaults to `false` (matches the live system: devices on the boat Wi-Fi must log in).
* `CAN_INTERFACE` is `can0`; `tools/canswitch.sh` sets `vcan0` for bench tests and `marine-doctor` flags it.

## Commands on the Pi

| Command | Purpose |
|---|---|
| `sudo marine-apply` | Render + apply everything now (idempotent). `--check` validates only; `--render-only` renders only. |
| `sudo marine-doctor` | Read-only report: config drift, services, bucket + recent data, `can0`, clock/RTC, journal, power, disk. `--json` also feeds the landing page. |
| `sudo marine-update` | `--check` / `--stage` / `--apply` / `--auto` against the release feed. Offline is a normal, quiet no-op. A failed apply rolls back and is not retried. |

## Releases

Tag `vX.Y.Z` → CI builds the image (arm64 + amd64), pins it by digest in `deploy/images.env`, bundles
`deploy/ config/ images/signalk/plugin.version marine.env.example VERSION`, and publishes the bundle plus
`releases/latest.json` (`version`, `bundle_url`, `bundle_sha256`) to GitHub Pages. The Pi verifies the sha256
before using anything, then pulls the images by digest.

CI needs: secrets `DOCKERHUB_USERNAME` (also the image namespace) and `DOCKERHUB_TOKEN`; Pages enabled (source: GitHub Actions),
with a tag rule `v*` on the `github-pages` environment (by default only `main` may deploy).

## The plugin

`images/signalk/plugin.version` pins the fork (`markhowells/signalk-to-influxdb2`) by **commit SHA**, plus the
SignalK base image by tag and digest. `plugin-sync.yml` reports weekly whether upstream (`tkurki`) has moved in a
way that conflicts with the fork. Bumping a pin is a normal reviewed commit.
