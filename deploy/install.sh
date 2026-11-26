#!/usr/bin/env bash
# install.sh — one-time host setup for the marine stack, then hands over to marine-apply.
# Replaces the old setup.sh. Safe to re-run.
#
#   sudo ./deploy/install.sh            from a checkout of this repo (or an extracted release)
#
# What it does (host-level only; all stack config is rendered by marine-apply):
#   packages (Docker, hostapd, dnsmasq, can-utils, fake-hwclock, …), wlan0 unmanaged +
#   static IP, can0 @ 250 kbps, persistent journal, /opt/marine layout, systemd units,
#   builds the SignalK image locally if no pinned registry image is configured yet,
#   starts Portainer (+ admin bootstrap), then runs marine-apply.
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT="$(dirname "$(dirname "$SELF")")"
ENV_FILE=/etc/marine/marine.env
OPT=/opt/marine
STATE=/var/lib/marine

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"

echo "==> marine.env"
if [[ ! -f "$ENV_FILE" ]]; then
    install -D -m 0600 "$ROOT/marine.env.example" "$ENV_FILE"
    echo "Created $ENV_FILE from the example. Fill in every 'changeme' (and the Influx org/bucket"
    echo "of any EXISTING database), then run this script again." >&2
    exit 1
fi
chmod 600 "$ENV_FILE"
# Validate before touching anything on the host.
python3 -I "$ROOT/deploy/lib/render.py" --env "$ENV_FILE" --images "$ROOT/deploy/images.env" --config "$ROOT/config" --check

echo "==> Installing packages"
apt-get update -qq
apt-get install -y ca-certificates curl gnupg
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    # bookworm repo: Docker may not publish trixie yet; the packages run fine on trixie.
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
fi
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin \
    hostapd dnsmasq can-utils python3-can rfkill iw fake-hwclock
usermod -aG docker "$REAL_USER"

echo "==> Unblocking WiFi / unmanaging wlan0 from NetworkManager"
rfkill unblock wlan || true
if command -v nmcli &>/dev/null; then
    nmcli device set wlan0 managed no || true
    install -D -m 0644 /dev/stdin /etc/NetworkManager/conf.d/99-marine-unmanaged.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF
fi
rm -f /etc/network/interfaces.d/wlan0
systemctl unmask hostapd 2>/dev/null || true

echo "==> Persistent journal (so failed boots leave evidence)"
mkdir -p /var/log/journal
systemctl restart systemd-journald || true

echo "==> Clock: fake-hwclock saves the time hourly and at shutdown; offline boots then start near the"
echo "    last real time instead of the last NTP sync. A DS3231 RTC is the proper fix (docs/boat-checklist.md)."
systemctl enable fake-hwclock 2>/dev/null || true
fake-hwclock save 2>/dev/null || true

echo "==> Layout under $OPT"
mkdir -p "$OPT" "$STATE" /etc/marine
if [[ ! -e "$OPT/current" ]]; then
    ln -sfn "$ROOT" "$OPT/current"   # first install from a checkout; marine-update replaces this with releases/<ver>
fi
for t in marine-apply marine-doctor marine-update; do
    ln -sfn "$OPT/current/deploy/$t" "/usr/local/sbin/$t"
done

echo "==> Static IP on wlan0 and can0 are installed by marine-apply (units + networkd file)"

# Local build of the SignalK image, only while no registry image is pinned yet.
SIGNALK_IMAGE="$(grep -E '^SIGNALK_IMAGE=' "$ROOT/deploy/images.env" | cut -d= -f2-)"
if [[ "$SIGNALK_IMAGE" != *"/"* && "$SIGNALK_IMAGE" != *"@sha256:"* ]]; then
    if ! docker image inspect "$SIGNALK_IMAGE" >/dev/null 2>&1 || [[ "${REBUILD:-0}" == 1 ]]; then
        echo "==> Building $SIGNALK_IMAGE locally (no registry image configured yet)"
        set -a; . "$ROOT/images/signalk/plugin.version"; set +a
        docker build -f "$ROOT/images/signalk/Dockerfile" \
            --build-arg SIGNALK_BASE --build-arg PLUGIN_REPO --build-arg PLUGIN_REF \
            -t "$SIGNALK_IMAGE" "$ROOT/images/signalk"
    fi
fi

echo "==> Rendering config and starting the stack"
"$ROOT/deploy/marine-apply"

echo "==> Portainer"
COMPOSE_ENV="$STATE/rendered/compose.env"
docker compose --env-file "$COMPOSE_ENV" -f "$ROOT/deploy/portainer.yml" up -d
PORTAINER_PW="$(grep -E '^PORTAINER_ADMIN_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"
for _ in $(seq 1 60); do curl -sf http://localhost:9000/api/status | grep -q '"Version"' && break; sleep 2; done
body="$(python3 -I -c 'import json,sys; print(json.dumps({"Username":"admin","Password":sys.argv[1]}))' "$PORTAINER_PW")"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:9000/api/users/admin/init -H 'Content-Type: application/json' -d "$body")"
case "$code" in 200) echo "    Portainer admin created." ;; 409) echo "    Portainer admin already exists." ;; *) echo "    WARN: Portainer admin init returned HTTP $code" ;; esac

echo "==> Enabling units"
systemctl daemon-reload
systemctl enable systemd-networkd hostapd dnsmasq          # AP and can0 must come back after a reboot
systemctl enable wlan0-static.service marine-stack.service portainer.service marine-update.timer
if ip link show wlan0 &>/dev/null; then systemctl restart wlan0-static.service; fi   # address before dnsmasq binds
systemctl enable --now marine-update.timer || true
systemctl restart hostapd dnsmasq 2>/dev/null || echo "WARN: hostapd/dnsmasq did not start — check 'journalctl -u hostapd' (WIFI_COUNTRY?)"

echo
echo "Done. Check everything with:  sudo marine-doctor"
echo "Log out and back in so docker group membership applies."
