# Pi operations: overview, upgrade, install, secrets

How the logger works on the Pi and how to look after it.
Building releases is in [release-guide.md](release-guide.md).

Written against release **v0.1.2** (November 2026).
**Read [section 9, known issues](#9-known-issues): two checks in `marine-doctor` give wrong answers.**

---

## 1. Quick reference

```bash
ssh -i ~/.ssh/lan.private mark@elemental.internal     # from the home LAN
                                                      # on the boat Wi-Fi the Pi is 10.42.0.1

sudo marine-doctor              # health and drift report, changes nothing
sudo marine-doctor --json       # same, and shows the result on the landing page
sudo marine-update --check      # is there a new release?
sudo marine-update              # download and apply it
sudo marine-apply               # re-apply config after editing marine.env
sudo nano /etc/marine/marine.env
docker logs --tail 100 signalk  # also influxdb, caddy, portainer
journalctl -u marine-update -u marine-stack
```

| Rule | Why |
|---|---|
| Edit only `/etc/marine/marine.env` on the Pi | everything else is overwritten from the release |
| Never rename the Compose project `pi` or the `pi_*` volumes | new empty volumes look like total data loss |
| Never delete or recreate `pi_influxdb_data` | it is the log |
| Never use `--remove-orphans` | Portainer and the stack share the project and would remove each other |
| Do not run `docker image prune -a` or `docker system prune` casually | removes staged and rollback images that cannot be re-downloaded at sea |
| Run installs and upgrades over wired Ethernet | `wlan0` is the boat access point and gets restarted |

---

## 2. Overview

### 2.1 Containers

| Container | Image | Network | Ports | Data volume | Job |
|---|---|---|---|---|---|
| `signalk` | `<namespace>/elemental-signalk` (ours) | host | 3000 | `pi_signalk_data` | reads CAN, serves vessel data, writes to InfluxDB |
| `influxdb` | `influxdb:2.7` | bridge `pi_marine_net` | 8086 | `pi_influxdb_data`, `pi_influxdb_config` | the log |
| `caddy` | `caddy:2` | host | 80, 443 | `pi_caddy_data`, `pi_caddy_config` | landing page and reverse proxy |
| `portainer` | `portainer-ce` | default | 9000, 9443 | `pi_portainer_data` | container management; has the Docker socket |

All restart unless stopped. Exact versions are pinned by digest in `deploy/images.env`.
`signalk`, `influxdb` and `caddy` are in `docker-compose.yml`; `portainer` is in `portainer.yml`.

On the boat Wi-Fi:

| Service | Name | Port form |
|---|---|---|
| Landing page | `http://elemental.internal/` | `http://10.42.0.1/` |
| SignalK | `http://signalk.elemental.internal/` | `:3000` |
| InfluxDB | `http://influx.elemental.internal/` | `:8086` |
| Portainer | `http://portainer.elemental.internal/` | `:9000` |

The names are served by the Pi's own DNS, so from the home network use `elemental.internal:<port>` only if
your router resolves that name, or the Pi's IP address.

### 2.2 Data path

```
NMEA 2000 bus ─ can0 (250 kbps)
   │  inside the signalk container:  candump can0 | candump2analyzer  -> analyzer
   ▼
SignalK server (:3000)
   │  plugin signalk-to-influxdb2
   ▼
InfluxDB (localhost:8086)   org = INFLUXDB_ORG, bucket = INFLUXDB_BUCKET
                            measurement "instruments", tag "sail_config"
```

- Live values: org `Elemental`, bucket `sailing_data`. The old `marine` / `signalk` bucket holds April 2026
  test data.
- Points are stamped with the **Pi's clock** (`useSKTimestamp: false`). The Pi has no real-time clock;
  `fake-hwclock` restores the last saved time at boot, so offline timestamps run behind by however long the
  Pi was off.
- Volume with defaults: about 2,500 points per second, mostly switch-bank state (see `INFLUX_IGNORED_PATHS`).
- The SignalK entrypoint applies managed config, copies the plugin from the image into the volume, then
  runs SignalK under a watchdog that restarts it if HTTP stops answering.

### 2.3 Release and config pipeline

```
git tag ─> CI ─> Docker Hub image + release bundle ─> GitHub Pages feed
                                                          │ marine-update (only when online)
                                                          ▼
/var/lib/marine/staged/<ver>   downloaded, checksum verified, images pulled
                                                          │ apply
                                                          ▼
/opt/marine/releases/<ver>  <── /opt/marine/current (symlink)
        +  /etc/marine/marine.env
                 │ marine-apply  (deploy/lib/render.py)
                 ▼
/var/lib/marine/rendered/ ──read-only──> containers
                          ──copied───> /etc/hostapd, /etc/dnsmasq.d, systemd units, can0.network
```

At v0.1.2, `/opt/marine/current` on your Pi points at `/home/mark/marine-0.1.2`, the directory of the first
install. **Do not delete that directory** while it is current or is your rollback target.

### 2.4 Where things live

| Path | Contents |
|---|---|
| `/etc/marine/marine.env` | your settings and secrets (root, 0600) |
| `/opt/marine/current` | the active release |
| `/opt/marine/releases/` | releases installed by `marine-update` |
| `/var/lib/marine/current.json` | installed version |
| `/var/lib/marine/rendered/` | generated config; `compose.env` feeds Docker Compose |
| `/var/lib/marine/staged/` | downloads; the file `READY` names the staged version |
| `/var/lib/marine/failed/` | versions that failed to apply and will not be retried |
| `/usr/local/sbin/marine-*` | links into the active release |
| `/var/lib/docker/volumes/pi_*` | data |

### 2.5 systemd units

| Unit | Job |
|---|---|
| `marine-stack.service` | at boot: wait up to 30 s for `can0`, then `compose up`. At shutdown: `compose down` (volumes are kept) |
| `portainer.service` | the same for Portainer |
| `wlan0-static.service` | gives `wlan0` the address `10.42.0.1/24` |
| `marine-update.timer` | runs `marine-update --auto` 5 minutes after boot and daily |
| `hostapd`, `dnsmasq` | access point; DHCP and DNS on `wlan0` |
| `systemd-networkd` | configures `can0` from `/etc/systemd/network/can0.network` |

---

## 3. Secrets and settings

### 3.1 `marine.env`

`/etc/marine/marine.env` is the only file that exists nowhere else. **Keep a copy** somewhere private.
Template: `marine.env.example`.

Format: `KEY=value`, one per line. **Do not quote values** and do not put comments after them: some scripts
read the file literally. Values passed to Docker Compose (the `INFLUXDB_*` ones and `DOMAIN`) must not
contain `$`, ` #`, leading or trailing spaces, or start with a quote.

To change a setting:

```bash
sudo cp -p /etc/marine/marine.env /etc/marine/marine.env.bak
sudo nano /etc/marine/marine.env
sudo marine-apply --check     # validate only
sudo marine-apply             # apply; restarts what changed
sudo marine-doctor
sudo rm /etc/marine/marine.env.bak     # once happy
```

Some secrets are also stored inside a service. For those, editing the file is **not enough** (section 3.3).

### 3.2 All variables

Required (the renderer refuses `changeme` and short values):

| Variable | Rule | Used for | Changing it |
|---|---|---|---|
| `WIFI_SSID` | 4+ chars | access point name | edit, apply. Devices reconnect |
| `WIFI_PASSWORD` | 8–63 | access point key | edit, apply. Devices need the new key |
| `PORTAINER_ADMIN_PASSWORD` | 12+ | creates the Portainer `admin` on first install only | see 3.3 |
| `INFLUXDB_USERNAME` | 1+ | first InfluxDB setup only | see 3.3 |
| `INFLUXDB_PASSWORD` | 8+ | first InfluxDB setup only | see 3.3 |
| `INFLUXDB_TOKEN` | 32+ | plugin writes; doctor checks; first setup | see 3.3 |
| `INFLUXDB_ORG` | 1+ | where SignalK writes | must already exist in InfluxDB; edit, apply |
| `INFLUXDB_BUCKET` | 1+ | where SignalK writes | create the bucket first; edit, apply |
| `VESSEL_NAME` | 1+ | SignalK vessel name, landing page | edit, apply |

Optional:

| Variable | Default | Meaning |
|---|---|---|
| `VESSEL_MMSI` | empty | MMSI in SignalK; empty removes it |
| `WIFI_COUNTRY` | `GB` | radio regulatory country |
| `CAN_INTERFACE` | `can0` | what SignalK reads (`vcan0` for bench tests, section 8) |
| `DOMAIN` | `elemental.internal` | host names served by DNS and Caddy |
| `TLS_MODE` | `off` | `off` = HTTP. `internal` = Caddy's own certificate authority (3.5) |
| `AUTO_APPLY` | `no` | `yes` lets the timer apply releases; `no` only downloads them |
| `UPDATE_URL` | the Pages feed | override the release feed |
| `SIGNALK_ALLOW_READONLY` | `false` | `true` lets anyone on the network read vessel data without logging in |
| `INFLUX_RESOLUTION_MS` | `0` | minimum interval between points per path; `1000` recommended to save space |
| `INFLUX_IGNORED_PATHS` | empty | comma-separated paths not logged, e.g. `electrical.switches.bank.*` |
| `INFLUX_PLUGIN_DEBUG` | `true` | plugin debug logging |

### 3.3 Secrets stored inside a service

**InfluxDB reads `INFLUXDB_USERNAME`, `_PASSWORD`, `_TOKEN`, `_ORG`, `_BUCKET` only when its data volume is
empty.** On an existing database you change InfluxDB first, then make `marine.env` match.

Back up first (section 4). The recovery commands here have **not been tried on this Pi**.

**API token (rotate):**
1. Log in to InfluxDB (`:8086`). Under *Load Data → API Tokens*, generate an **All Access** token and copy it.
2. Put it in `INFLUXDB_TOKEN`, then `sudo marine-apply`. InfluxDB is recreated and SignalK restarted.
3. `sudo marine-doctor`: `destination bucket` must be OK, and with CAN data, `recent data` too.
4. Only then delete the old token in the UI. If the old one is the original operator token, keep it,
   stored privately.

**Login password:** change it in the InfluxDB UI, or:
```bash
sudo -i
read -rs INFLUX_TOKEN && export INFLUX_TOKEN        # paste the token; nothing is echoed
docker exec -it -e INFLUX_TOKEN influxdb influx user password -n <username>
exit
```
Then update `INFLUXDB_PASSWORD` for your records.

**Lost token:** look in `/etc/marine/marine.env` and its backups, then
`docker exec influxdb cat /etc/influxdb2/influx-configs`. As a last resort, create a new operator token with
the server stopped:
```bash
IMG=$(docker inspect -f '{{.Config.Image}}' influxdb)
docker stop influxdb
docker run --rm -v pi_influxdb_data:/var/lib/influxdb2 --entrypoint influxd "$IMG" \
    recovery auth create-operator --bolt-path /var/lib/influxdb2/influxd.bolt \
    --username <username> --org <org>
docker start influxdb
```

**Portainer password:** change it in the UI (*My account*), then update `marine.env` to match. If lost
(needs Internet to fetch the helper):
```bash
docker stop portainer
docker run --rm -v pi_portainer_data:/data portainer/helper-reset-password   # prints a new password
docker start portainer
```

**SignalK users and device tokens:** not in `marine.env`. They live in `security.json` in
`pi_signalk_data` and releases never touch them. Manage them in the SignalK UI under *Security*. If locked
out, this removes **all** users and device tokens; SignalK then asks you to create a new administrator:
```bash
docker exec signalk cp /home/node/.signalk/security.json /home/node/.signalk/security.json.bak
docker exec signalk rm /home/node/.signalk/security.json
docker restart signalk
```

### 3.4 Where copies of secrets exist

| Copy | Holds |
|---|---|
| `/etc/marine/marine.env` | everything |
| `/var/lib/marine/rendered/compose.env`, `hostapd.conf`, `signalk/` | InfluxDB credentials, token, Wi-Fi key |
| `/etc/hostapd/hostapd.conf` | Wi-Fi key |
| `pi_signalk_data` | token (plugin config), SignalK users |
| InfluxDB container environment (visible in Portainer and `docker inspect`) | InfluxDB credentials and token |
| `~/pi` on the Pi (pre-release checkout: `marine.conf`, `.influx-token`) | old credentials |
| every backup, on the Pi and on the devbox | everything in the volumes and files above |

None of this belongs in git, a bug report or a chat window.

Other keys, which never reach the Pi's configuration:

| Key | Where | Use |
|---|---|---|
| `~/.ssh/lan.private` | devbox | SSH to the Pi |
| `~/.ssh/github.key` | devbox | push to GitHub |
| `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` | GitHub Actions secrets | publish images ([release guide](release-guide.md#4-github-setup-once-or-if-recreating-the-repo)) |

To replace the Pi SSH key, add the new public key to `~/.ssh/authorized_keys` on the Pi and test it in a
second session before removing the old one.

### 3.5 TLS mode (untested on this Pi)

With `TLS_MODE=internal`, Caddy issues its own certificates, which works offline. Each phone or laptop must
trust its root certificate once:
```bash
docker cp caddy:/data/caddy/pki/authorities/local/root.crt ./marine-root.crt
```
Install that file on the device and mark it trusted. The direct ports (3000, 8086, 9000) stay plain HTTP.

### 3.6 Other environment variables

You should not normally need these.

| Variable | Used by | Meaning |
|---|---|---|
| `MARINE_ENV` | apply, doctor, update, canswitch | other path for `marine.env` |
| `MARINE_STATE_DIR` | apply, doctor, update | other path for `/var/lib/marine` |
| `MARINE_ROOT` | apply, doctor | release directory to use |
| `MARINE_OPT_DIR` | update | other path for `/opt/marine` |
| `MARINE_UPDATE_URL` | update | one-off feed override (beats `UPDATE_URL`) |
| `MARINE_DRY_RUN` | update | `1` = no Docker or apply (tests) |
| `REBUILD` | install | `1` = rebuild a locally built image |
| `SIGNALK_IMAGE`, `INFLUXDB_IMAGE`, `CADDY_IMAGE`, `PORTAINER_IMAGE` | Compose, from `images.env` | pinned images |
| `MARINE_RENDERED` | Compose, from `compose.env` | rendered config directory |
| `DOCKER_INFLUXDB_INIT_*` | InfluxDB container | first-time database setup |
| `IS_IN_DOCKER`, `CONTAINER_RUNTIME` | set by the SignalK entrypoint | tells SignalK it is containerised |
| `PLUGIN_REPO`, `PLUGIN_REF`, `SIGNALK_BASE` | image build | pins in `plugin.version` |

---

## 4. Backup and restore

### 4.1 Backup

Stops the containers for a few minutes, so do not do it while logging. Needs about 2 GB free (growing with
the data). Save this as `~/marine-backup.sh` on the Pi and run `sudo bash ~/marine-backup.sh`.

```bash
#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
U="${SUDO_USER:?run via sudo from your own account}"; H="$(getent passwd "$U" | cut -d: -f6)"
B="$H/backup-$(date +%Y%m%d-%H%M)"; mkdir -m 700 "$B"
IMG="$(docker inspect -f '{{.Config.Image}}' influxdb)"
mapfile -t running < <(docker ps --format '{{.Names}}')
restart() { if ((${#running[@]})); then docker start "${running[@]}"; fi; }
trap restart EXIT
if ((${#running[@]})); then docker stop "${running[@]}"; fi
for v in pi_influxdb_data pi_influxdb_config pi_signalk_data pi_portainer_data; do
    docker volume inspect "$v" >/dev/null            # fail rather than create an empty volume
    docker run --rm --entrypoint tar -v "$v":/d:ro -v "$B":/b "$IMG" -czf "/b/$v.tgz" -C /d .
done
tar -czf "$B/host.tgz" -C / etc/marine etc/systemd/network
for f in "$B"/*.tgz; do tar -tzf "$f" >/dev/null; done
(cd "$B" && sha256sum ./*.tgz > SHA256SUMS)
chown -R "$U": "$B"; ls -lh "$B"
echo "DONE: $B (contains secrets; copy it off the Pi)"
```

Copy it to the devbox and **check it arrived whole** (a full disk once truncated a copy):

```bash
df -h ~
scp -r -i ~/.ssh/lan.private mark@elemental.internal:backup-YYYYMMDD-HHMM ~/
cd ~/backup-YYYYMMDD-HHMM && sha256sum -c SHA256SUMS      # every line must say OK
```

The backup made before the v0.1.2 cutover (`~/backup-20261126-1709` on the devbox) predates
`/etc/marine/marine.env` and does not contain it.

### 4.2 Restore (not yet rehearsed)

This **overwrites the current data**. On a new Pi, complete a fresh install first, then:

```bash
cd ~/backup-YYYYMMDD-HHMM && sha256sum -c SHA256SUMS      # stop if anything fails
B="$PWD"; IMG=$(docker inspect -f '{{.Config.Image}}' influxdb)
docker stop signalk influxdb caddy portainer
for v in pi_influxdb_data pi_influxdb_config pi_signalk_data pi_portainer_data; do
    docker volume inspect "$v" >/dev/null || break
    docker run --rm --entrypoint sh -v "$v":/d -v "$B":/b:ro "$IMG" \
        -c "find /d -mindepth 1 -delete && tar -xzf /b/$v.tgz -C /d"
done
```

Then make `/etc/marine/marine.env` match the restored database (restore it from `host.tgz` if present), and:

```bash
docker start influxdb portainer
sudo marine-apply && docker restart signalk caddy
sudo marine-doctor
```

---

## 5. Upgrading an existing installation

### 5.1 Normal upgrade

Pi on wired Ethernet with Internet. Back up first if InfluxDB changes.

```bash
sudo marine-doctor                       # know the starting state
sudo cat /var/lib/marine/current.json    # installed version
df -h /                                  # a few GB free
sudo marine-update --check               # anything new?
sudo marine-update --stage               # download, verify, pull images; changes nothing running
```

Look before applying:

```bash
V=$(sudo cat /var/lib/marine/staged/READY)
sudo /var/lib/marine/staged/$V/x/deploy/marine-apply --check       # does marine.env satisfy it?
sudo diff /opt/marine/current/deploy/images.env /var/lib/marine/staged/$V/x/deploy/images.env
```

Apply and check:

```bash
sudo marine-update --apply
sudo marine-doctor
```

Afterwards, only if relevant:

| If | Then |
|---|---|
| `PORTAINER_IMAGE` changed | `sudo docker compose --env-file /var/lib/marine/rendered/compose.env -f /opt/marine/current/deploy/portainer.yml up -d` (`marine-apply` does not do Portainer) |
| `install.sh` changed (packages, enabling units) | `sudo /opt/marine/current/deploy/install.sh` |

Finish with `sudo reboot` and another `sudo marine-doctor` if units, networking or `install.sh` changed.

`sudo marine-update` with no option does check, stage and apply in one go.

**Automatic behaviour:** the timer stages new releases whenever the Pi is online. With the default
`AUTO_APPLY=no` nothing changes until you run `--apply`. With `yes`, it applies unattended.

**Do not use `install.sh` from a new bundle to upgrade.** It applies the new files but leaves
`/opt/marine/current` pointing at the old release, so the next boot mixes the two.

### 5.2 When an upgrade fails

`marine-update` applies, checks that InfluxDB and SignalK answer, and otherwise **switches back to the
previous release** and records the failure. Caddy, Wi-Fi and Portainer are not part of that check.

| Message | Meaning and action |
|---|---|
| `offline or release feed unreachable` | check Ethernet and the feed URL |
| `pull failed` | network or Docker Hub; run again later. Old release still running |
| `bundle checksum mismatch` | corrupt or republished download; run `--stage` again after ten minutes |
| `apply FAILED — rolling back` | see below |
| `previously failed to apply — skipping` | fix the cause, `sudo rm /var/lib/marine/failed/<ver>`, `sudo marine-update` |
| `rollback apply also failed` | `sudo marine-doctor`, then roll back by hand |

Find the cause: `journalctl -u marine-update`, `docker logs signalk`, `docker logs influxdb`.

### 5.3 Rolling back by hand

```bash
ls /opt/marine/releases/ /home/mark/marine-*          # what is available
OLD=/opt/marine/releases/<ver>                        # or /home/mark/marine-0.1.2
sudo ln -sfn "$OLD" /opt/marine/current.new && sudo mv -T /opt/marine/current.new /opt/marine/current
sudo marine-apply
sudo mkdir -p /var/lib/marine/failed && sudo touch /var/lib/marine/failed/<bad-version>
sudo rm -f /var/lib/marine/staged/READY
```

The old images must still be on the Pi (or it must be online). Rolling back does not undo a database
upgrade made by a newer InfluxDB: restore a backup for that.

### 5.4 Applying a bundle without the feed

Useful if Pages is broken. The Pi **still needs Internet** to pull images it does not already have.

```bash
V=0.1.3
sudo mkdir /opt/marine/releases/$V
sudo tar -xzf marine-$V.tar.gz -C /opt/marine/releases/$V --no-same-owner
sudo /opt/marine/releases/$V/deploy/marine-apply --check
sudo ln -sfn /opt/marine/releases/$V /opt/marine/current.new && sudo mv -T /opt/marine/current.new /opt/marine/current
sudo marine-apply
```

Verify the download's SHA-256 against the GitHub Release or the Pages page first.

### 5.5 `--render-only` caution

`sudo <release>/deploy/marine-apply --render-only` overwrites the live rendered files, including the image
list used at the next boot. If you use it, follow with a real `marine-apply`, and restart SignalK and Caddy
yourself (`docker restart signalk caddy`), because the apply will no longer see those files as changed.

---

## 6. Fresh installation

Needs: Raspberry Pi 4B, SD card, MCP2515-style CAN HAT, wired Ethernet with Internet, and your saved
`marine.env`. The whole sequence has not been run on a blank card; the installer has only been run on the
existing Pi (and rehearsed with system commands faked).

### 6.1 Operating system

1. Flash **Raspberry Pi OS Lite, 64-bit (Debian 13 trixie)** with Raspberry Pi Imager. Set host name
   `elemental`, your user, and enable SSH. Do not configure Wi-Fi.
2. Boot on Ethernet and SSH in.
3. Enable the CAN hardware: add to `/boot/firmware/config.txt` (values for the current dual-channel HAT;
   check yours):
   ```
   dtparam=spi=on
   dtoverlay=mcp2515-can0,oscillator=16000000,interrupt=23
   dtoverlay=mcp2515-can1,oscillator=16000000,interrupt=25
   ```
4. Make the journal persistent (the installer does not manage this on Raspberry Pi OS, section 9):
   ```bash
   sudo mkdir -p /etc/systemd/journald.conf.d /var/log/journal
   printf '[Journal]\nStorage=persistent\nSystemMaxUse=200M\n' | sudo tee /etc/systemd/journald.conf.d/50-marine-persistent.conf
   ```
5. `sudo reboot`, then `ip link show can0` must list the interface.
6. Check `sudo apt-get update` finishes without `E:` lines. The installer stops if it does not.

### 6.2 Install the release

Take the version shown in the feed or on the Pages front page.

```bash
V=0.1.2
cd ~
curl -fLO https://github.com/markhowells/elemental-logger/releases/download/v$V/marine-$V.tar.gz
sha256sum marine-$V.tar.gz        # compare with the Release page / Pages page
sudo mkdir -p /opt/marine/releases/$V
sudo tar -xzf marine-$V.tar.gz -C /opt/marine/releases/$V --no-same-owner
sudo /opt/marine/releases/$V/deploy/install.sh     # first run: creates marine.env and stops
sudo nano /etc/marine/marine.env                   # fill in, or paste your saved copy
sudo /opt/marine/releases/$V/deploy/install.sh     # second run: installs and starts everything
```

Install from a **release bundle**, not a git checkout: a checkout builds the image on the Pi instead of
using the published one.

New InfluxDB token, if you need one: `openssl rand -hex 32`.

What the installer does: installs missing packages (never upgrades) including Docker, hands `wlan0` to the
access point, enables the journal directory and `fake-hwclock`, creates `/opt/marine` and the `marine-*`
commands, runs `marine-apply`, starts Portainer and creates its admin, and enables the units.

### 6.3 First-run tasks

1. **Immediately** open SignalK (`http://<pi>:3000`) and create the administrator account. Until you do,
   anyone on the network can.
2. Log in to InfluxDB (`:8086`) with `INFLUXDB_USERNAME` / `INFLUXDB_PASSWORD`; check org and bucket.
3. Log in to Portainer (`:9000`) as `admin`.
4. Restoring old data? Do section 4.2 now.
5. `sudo reboot`, wait a few minutes, `sudo marine-doctor --json`.
6. Check the journal kept both boots: `journalctl --list-boots` must show rows `-1` and `0`.
7. Join the boat Wi-Fi from a phone and open `http://elemental.internal/`.
8. Test with real or virtual CAN data (section 8) before relying on it.

---

## 7. Reading `marine-doctor`

| Check | If not OK |
|---|---|
| `marine.env permissions` | `sudo chmod 600 /etc/marine/marine.env` |
| `config renders` | the message names the bad variable |
| `plugin config drift`, `settings drift` | `sudo marine-apply`. If it returns, something edits the live config |
| `InfluxDB`, `SignalK`, `Landing page` | `docker ps -a`, `docker logs <name>`, `sudo marine-apply` |
| `destination bucket` | org, bucket or token in `marine.env` do not match InfluxDB |
| `recent data` | normal on the bench. Underway: check `can0`, SignalK data, plugin log |
| `can0` | wiring, `config.txt` overlay, `systemctl status systemd-networkd` |
| `clock`, `RTC` | see section 9 |
| `persistent journal` | see section 9 |
| `power` | undervoltage: supply or cable |
| `disk` | InfluxDB growth or old images |

A log line `DRIFT: live InfluxDB plugin config differed ... overwriting` is the entrypoint correcting the
volume copy. Right after a first install it can be a formatting difference only.

Disk clean-up, only after the current release has proved itself: remove old directories under
`/opt/marine/releases/` and `/var/lib/marine/staged/`, keeping the current and previous versions, and remove
specific old images with `docker rmi`.

For boat trips use [boat-checklist.md](boat-checklist.md).

---

## 8. Bench testing with a virtual CAN bus

> Test frames are logged to the **real** InfluxDB bucket with real timestamps.

`tools/canswitch.sh` is not in the release bundle, so on the Pi:

```bash
sudo modprobe vcan
sudo ip link add dev vcan0 type vcan
sudo ip link set up vcan0
sudo nano /etc/marine/marine.env        # CAN_INTERFACE=vcan0
sudo marine-apply
cansend vcan0 09F50B00#00640000000000FF     # water depth 1.0 m (PGN 128267)
```

Look for the value in SignalK (*Data Browser*) and in InfluxDB. **Afterwards** set `CAN_INTERFACE=can0` and
run `sudo marine-apply`. `marine-doctor` warns while test mode is on.

---

## 9. Known issues

As of v0.1.2. Delete entries as they are fixed.

| Issue | Effect | Work-around / fix |
|---|---|---|
| **Journal is not persistent.** Raspberry Pi OS ships `Storage=volatile` in `/usr/lib/systemd/journald.conf.d/`, which overrides the `/var/log/journal` directory the installer creates | logs are lost at every reboot, so a failed boat boot leaves no evidence | add the override in section 6.1 step 4, `sudo systemctl restart systemd-journald && sudo journalctl --flush`, reboot, check `journalctl --list-boots`. To fix in `install.sh` |
| **`persistent journal` check is wrong**: it counts the header line of `journalctl --list-boots` | reports "2 boots recorded" with one boot | check `journalctl --list-boots` yourself. To fix in `marine-doctor` |
| **`clock` / `RTC` checks are wrong on trixie**: they test the masked unit `fake-hwclock` instead of `fake-hwclock-load.service` | `RTC none`, and **offline a false `FAIL clock`** (non-zero exit) | check `systemctl is-enabled fake-hwclock-load.service`. To fix in `marine-doctor` |
| `can0.network` has no automatic restart after a CAN bus-off fault | logging stops until the interface is restarted | `sudo ip link set can0 down && sudo ip link set can0 up`, or reboot. To fix: `RestartSec=` in `[CAN]` |
| Installer runs `apt-get update` even when nothing is missing | an unrelated broken package source stops it | disable that source. `pxvirt-sources.list` was renamed to `.disabled` for this reason |
| `marine-apply` health check ignores Caddy, Wi-Fi and Portainer | a release can "succeed" with those broken | run `marine-doctor` and join the Wi-Fi after upgrading |
| Landing page shows no status | nothing runs `marine-doctor --json` automatically | run it by hand |
| `tools/smoke-test.sh` can delete the `pi_*` volumes | data loss if run on the Pi | never run it on the Pi |
| Logging has not been verified end to end on the real Pi since v0.1.2 | unproven | after the next trip, query `sailing_data` for the trip period |
| No data May–October 2026 | cause unknown | [boat-checklist.md](boat-checklist.md) |
