#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
CONF="${SCRIPT_DIR}/marine.conf"
if [[ ! -f "$CONF" ]]; then
    echo "ERROR: marine.conf not found. Copy it from the repo and fill in all values." >&2
    exit 1
fi
# shellcheck source=marine.conf
source "$CONF"

# ---------------------------------------------------------------------------
# 1. Root check
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Pre-flight: reject placeholder values
# ---------------------------------------------------------------------------
ERRORS=0
check() {
    local name="$1" value="$2" min_len="${3:-1}"
    if [[ "$value" == *"changeme"* ]]; then
        echo "  ERROR: $name still contains 'changeme' — update marine.conf" >&2
        ERRORS=$((ERRORS + 1))
    elif [[ ${#value} -lt $min_len ]]; then
        echo "  ERROR: $name must be at least $min_len characters" >&2
        ERRORS=$((ERRORS + 1))
    fi
}

echo "==> Checking marine.conf..."
check "WIFI_SSID"                "$WIFI_SSID"                4
check "WIFI_PASSWORD"            "$WIFI_PASSWORD"            8
check "PORTAINER_ADMIN_PASSWORD" "$PORTAINER_ADMIN_PASSWORD" 12
check "INFLUXDB_PASSWORD"        "$INFLUXDB_PASSWORD"        8
check "INFLUXDB_TOKEN"           "$INFLUXDB_TOKEN"           32
check "INFLUXDB_ORG"             "$INFLUXDB_ORG"             1
check "INFLUXDB_BUCKET"          "$INFLUXDB_BUCKET"          1
check "VESSEL_NAME"              "$VESSEL_NAME"              1

if [[ $ERRORS -gt 0 ]]; then
    echo "" >&2
    echo "Fix the above in marine.conf and re-run." >&2
    exit 1
fi
echo "    All values look good."

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"

# ---------------------------------------------------------------------------
# 2. Install packages
# ---------------------------------------------------------------------------
echo "==> Installing packages"
apt-get update -qq
apt-get install -y ca-certificates curl gnupg

# Add Docker's official apt repository if not already present
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    echo "==> Adding Docker apt repository"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Use bookworm as the repo codename — Docker may not yet publish trixie,
    # but bookworm packages run fine on trixie.
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
fi

apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-compose-plugin \
    hostapd \
    dnsmasq \
    can-utils \
    canboat \
    python3-can \
    rfkill \
    iw

# ---------------------------------------------------------------------------
# 3. Unblock WiFi
# ---------------------------------------------------------------------------
echo "==> Unblocking WiFi"
rfkill unblock wlan || true

# ---------------------------------------------------------------------------
# 4. Stop NetworkManager managing wlan0 (it fights hostapd)
# ---------------------------------------------------------------------------
if command -v nmcli &>/dev/null; then
    echo "==> Unmanaging wlan0 from NetworkManager"
    nmcli device set wlan0 managed no || true
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/99-marine-unmanaged.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF
fi

# ---------------------------------------------------------------------------
# 5. Static IP on wlan0 via systemd oneshot
# ---------------------------------------------------------------------------
echo "==> Configuring static IP on wlan0 (10.42.0.1/24)"
rm -f /etc/network/interfaces.d/wlan0
cp "$SCRIPT_DIR/systemd/wlan0-static.service" /etc/systemd/system/wlan0-static.service
systemctl daemon-reload
systemctl enable wlan0-static.service
# Apply immediately if wlan0 is already present; the service handles it at boot otherwise
if ip link show wlan0 &>/dev/null; then
    ip addr replace 10.42.0.1/24 dev wlan0
    ip link set wlan0 up
fi

# ---------------------------------------------------------------------------
# 6. Configure can0 at NMEA 2000 standard bitrate (250 kbps)
# ---------------------------------------------------------------------------
echo "==> Configuring can0 (250 kbps)"
cp "$SCRIPT_DIR/config/can0.network" /etc/systemd/network/can0.network
systemctl enable systemd-networkd
systemctl restart systemd-networkd

# Bring up immediately without waiting for reboot
if ip link show can0 &>/dev/null; then
    ip link set can0 type can bitrate 250000 2>/dev/null || true
    ip link set can0 up 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 7. hostapd
# ---------------------------------------------------------------------------
echo "==> Configuring hostapd"

# Inject SSID, password, and country code
sed \
    -e "s/^ssid=.*/ssid=${WIFI_SSID}/" \
    -e "s/^wpa_passphrase=.*/wpa_passphrase=${WIFI_PASSWORD}/" \
    -e "s/^country_code=.*/country_code=${WIFI_COUNTRY}/" \
    "$SCRIPT_DIR/config/hostapd.conf" > /etc/hostapd/hostapd.conf

sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF=/etc/hostapd/hostapd.conf|' /etc/default/hostapd
systemctl unmask hostapd
systemctl enable hostapd

# ---------------------------------------------------------------------------
# 8. dnsmasq
# ---------------------------------------------------------------------------
echo "==> Configuring dnsmasq"
cp "$SCRIPT_DIR/config/dnsmasq.conf" /etc/dnsmasq.d/marine.conf
systemctl enable dnsmasq

# ---------------------------------------------------------------------------
# 9. Add user to docker group
# ---------------------------------------------------------------------------
echo "==> Adding $REAL_USER to docker group"
usermod -aG docker "$REAL_USER"

# ---------------------------------------------------------------------------
# 10. Build the SignalK image
#     Done before starting Portainer to avoid hitting the 5-minute admin
#     setup timeout while the build is running.
# ---------------------------------------------------------------------------
echo "==> Writing SignalK settings from marine.conf"
sed \
    -e "s|VESSEL_NAME_PLACEHOLDER|${VESSEL_NAME}|g" \
    -e "s|VESSEL_MMSI_PLACEHOLDER|${VESSEL_MMSI}|g" \
    "${SCRIPT_DIR}/config/signalk/settings.json.template" \
    > "${SCRIPT_DIR}/config/signalk/settings.json"

echo "==> Writing SignalK plugin config from marine.conf"
sed \
    -e "s|INFLUXDB_TOKEN_PLACEHOLDER|${INFLUXDB_TOKEN}|g" \
    -e "s|INFLUXDB_ORG_PLACEHOLDER|${INFLUXDB_ORG}|g" \
    -e "s|INFLUXDB_BUCKET_PLACEHOLDER|${INFLUXDB_BUCKET}|g" \
    "${SCRIPT_DIR}/config/signalk/plugin-config-data/signalk-to-influxdb2.json.template" \
    > "${SCRIPT_DIR}/config/signalk/plugin-config-data/signalk-to-influxdb2.json"

echo "==> Building marine-signalk image"
docker build -t marine-signalk:latest "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# 11. Install and start Portainer
# ---------------------------------------------------------------------------
echo "==> Installing portainer.service"
echo "==> Pulling Portainer image"
docker compose -f "$SCRIPT_DIR/portainer-bootstrap.yml" pull

sed "s|SCRIPT_DIR_PLACEHOLDER|${SCRIPT_DIR}|g" \
    "$SCRIPT_DIR/systemd/portainer.service" > /etc/systemd/system/portainer.service
systemctl daemon-reload
systemctl enable portainer.service
systemctl restart portainer.service

# ---------------------------------------------------------------------------
# 12. Bootstrap Portainer admin user via API
# ---------------------------------------------------------------------------
echo "==> Waiting for Portainer to be ready..."
TRIES=0
until curl -sf http://localhost:9000/api/status | grep -q '"Version"'; do
    sleep 2
    TRIES=$((TRIES + 1))
    if [[ $TRIES -gt 60 ]]; then
        echo "ERROR: Portainer did not start within 120s. Check: docker logs portainer" >&2
        exit 1
    fi
done
echo "    Portainer ready."

echo "==> Creating Portainer admin user"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST http://localhost:9000/api/users/admin/init \
    -H "Content-Type: application/json" \
    -d "{\"Username\":\"admin\",\"Password\":\"${PORTAINER_ADMIN_PASSWORD}\"}")

if [[ "$HTTP_STATUS" == "200" ]]; then
    echo "    Admin user created."
elif [[ "$HTTP_STATUS" == "409" ]]; then
    echo "    Admin user already exists, skipping."
else
    echo "ERROR: Failed to create admin user (HTTP $HTTP_STATUS)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 13. Start WiFi AP and DHCP
# ---------------------------------------------------------------------------
echo "==> Starting hostapd and dnsmasq"
systemctl restart hostapd || echo "WARN: hostapd failed — check country_code (${WIFI_COUNTRY}) in hostapd.conf"

# Ensure wlan0 has its static IP before dnsmasq tries to bind to it
if ip link show wlan0 &>/dev/null; then
    ip addr replace 10.42.0.1/24 dev wlan0
    ip link set wlan0 up
fi
systemctl restart dnsmasq || echo "WARN: dnsmasq failed to start — will retry at boot"

# ---------------------------------------------------------------------------
# Write final docker-compose.yml with values from marine.conf
# ---------------------------------------------------------------------------
echo "==> Writing docker-compose.yml with configured values"
sed \
    -e "s|SCRIPT_DIR_PLACEHOLDER|${SCRIPT_DIR}|g" \
    -e "s|INFLUXDB_USERNAME_PLACEHOLDER|${INFLUXDB_USERNAME}|g" \
    -e "s|INFLUXDB_PASSWORD_PLACEHOLDER|${INFLUXDB_PASSWORD}|g" \
    -e "s|INFLUXDB_TOKEN_PLACEHOLDER|${INFLUXDB_TOKEN}|g" \
    -e "s|INFLUXDB_ORG_PLACEHOLDER|${INFLUXDB_ORG}|g" \
    -e "s|INFLUXDB_BUCKET_PLACEHOLDER|${INFLUXDB_BUCKET}|g" \
    "${SCRIPT_DIR}/docker-compose.yml.template" > "${SCRIPT_DIR}/docker-compose.yml"

# ---------------------------------------------------------------------------
# 14. Install and start marine-stack.service
# ---------------------------------------------------------------------------
echo "==> Installing marine-stack.service"
sed "s|SCRIPT_DIR_PLACEHOLDER|${SCRIPT_DIR}|g" \
    "$SCRIPT_DIR/systemd/marine-stack.service" > /etc/systemd/system/marine-stack.service
systemctl daemon-reload
systemctl enable marine-stack.service
systemctl restart marine-stack.service

# ---------------------------------------------------------------------------
# 15. Verify
# ---------------------------------------------------------------------------
echo "==> Waiting 20s for services to start..."
sleep 20

if curl -sf http://localhost:8086/health | grep -q '"status":"pass"'; then
    echo "    InfluxDB: OK"
else
    echo "    InfluxDB: not yet healthy — check: docker logs influxdb"
fi

if curl -sf http://localhost:3000/signalk > /dev/null; then
    echo "    SignalK:  OK"
else
    echo "    SignalK:  not yet responding — check: docker logs signalk"
fi

echo ""
echo "================================================================"
echo "  Setup complete."
echo ""
echo "  Portainer: http://$(hostname -I | awk '{print $1}'):9000"
echo "             login: admin / ${PORTAINER_ADMIN_PASSWORD}"
echo "  SignalK:   http://$(hostname -I | awk '{print $1}'):3000"
echo "  InfluxDB:  http://$(hostname -I | awk '{print $1}'):8086"
echo "             login: ${INFLUXDB_USERNAME} / ${INFLUXDB_PASSWORD}"
echo ""
echo "  WiFi SSID: ${WIFI_SSID}"
echo "  WiFi pass: ${WIFI_PASSWORD}"
echo ""
echo "  To update SignalK after changing the Dockerfile:"
echo "    docker build -t marine-signalk:latest ${SCRIPT_DIR}"
echo "    sudo systemctl restart marine-stack"
echo ""
echo "  NOTE: Log out and back in for docker group to take effect."
echo "================================================================"
