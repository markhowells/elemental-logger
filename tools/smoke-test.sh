#!/usr/bin/env bash
# End-to-end smoke test: CAN frame -> SignalK -> signalk-to-influxdb2 -> InfluxDB, using a
# virtual CAN interface named can0 and throw-away credentials. Needs Docker and root (vcan).
#
#   SIGNALK_IMAGE=elemental-signalk:ci tools/smoke-test.sh
#
# Used by CI; also runnable on the devbox (needs `sudo`, `can-utils`, and the vcan kernel module).
#
# It must never touch a real install: it uses its own volume and network names, and refuses to run
# where a marine stack exists, because its clean-up deletes the volumes it used.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGNALK_IMAGE:?set SIGNALK_IMAGE to the image under test}"

# ── safety checks: nothing is changed (and no clean-up is armed) until all of these pass ──────
refuse() { echo "smoke-test: REFUSING to run: $*" >&2; exit 1; }
[[ ! -e "${MARINE_ENV:-/etc/marine/marine.env}" ]] || refuse "this machine has a marine install (marine.env exists)"
volumes="$(docker volume ls --format '{{.Name}}')"
! grep -q '^pi_' <<<"$volumes" || refuse "pi_* volumes exist here (real data)"
containers="$(docker ps -a --format '{{.Names}}')"
! grep -qxE 'signalk|influxdb|caddy' <<<"$containers" || refuse "a signalk, influxdb or caddy container already exists"
if ip link show can0 >/dev/null 2>&1 && ! ip -details link show can0 | grep -qw vcan; then
    refuse "can0 is a real CAN interface"
fi

W="$(mktemp -d)"
made_can0=0
COMPOSE=(docker compose -p smoke --env-file "$W/rendered/compose.env" -f deploy/docker-compose.yml -f "$W/isolate.yml")
stack_started=0
cleanup() {
    if [[ $stack_started -eq 1 ]]; then "${COMPOSE[@]}" down -v >/dev/null 2>&1 || true; fi
    if [[ $made_can0 -eq 1 ]]; then sudo ip link del can0 2>/dev/null || true; fi
    rm -rf "$W"
}
trap cleanup EXIT

# The shipped compose file pins the production volume and network names; replace every one of them.
cat > "$W/isolate.yml" <<'YML'
networks:
  marine_net: {name: smoke_marine_net}
volumes:
  signalk_data: {name: smoke_signalk_data}
  influxdb_data: {name: smoke_influxdb_data}
  influxdb_config: {name: smoke_influxdb_config}
  caddy_data: {name: smoke_caddy_data}
  caddy_config: {name: smoke_caddy_config}
YML

echo "==> virtual CAN (named can0, as production)"
sudo modprobe vcan
if ! ip link show can0 >/dev/null 2>&1; then sudo ip link add dev can0 type vcan; made_can0=1; fi
sudo ip link set up can0

echo "==> render config with test credentials"
cat > "$W/test.env" <<ENV
WIFI_SSID=SmokeNet
WIFI_PASSWORD=smoke-test-wifi
PORTAINER_ADMIN_PASSWORD=smoke-test-portainer
INFLUXDB_USERNAME=admin
INFLUXDB_PASSWORD=smoke-test-influx
INFLUXDB_TOKEN=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
INFLUXDB_ORG=Smoke
INFLUXDB_BUCKET=smoke_data
VESSEL_NAME=Smoke
ENV
# Use the image under test, keep every other pin as shipped.
grep -v '^SIGNALK_IMAGE=' deploy/images.env > "$W/images.env"; echo "SIGNALK_IMAGE=$SIGNALK_IMAGE" >> "$W/images.env"
python3 -I deploy/lib/render.py --env "$W/test.env" --images "$W/images.env" --config config --out "$W/rendered" --version smoke
TOKEN="$(grep '^INFLUXDB_TOKEN=' "$W/test.env" | cut -d= -f2-)"

echo "==> start stack"
resolved="$("${COMPOSE[@]}" config)"
! grep -qE 'name: pi_' <<<"$resolved" || refuse "a production volume or network name is not overridden in isolate.yml"
stack_started=1
"${COMPOSE[@]}" up -d

echo "==> wait for services"
for _ in $(seq 1 90); do
    curl -sf http://localhost:8086/health | grep -q '"status":"pass"' && curl -sf http://localhost:3000/signalk >/dev/null && break
    sleep 2
done
curl -sf http://localhost:8086/health | grep -q pass || { echo "InfluxDB not healthy"; docker logs influxdb | tail -20; exit 1; }
curl -sf http://localhost:3000/signalk >/dev/null    || { echo "SignalK not responding"; docker logs signalk | tail -40; exit 1; }
curl -sf http://localhost/ | grep -qi 'Smoke' || { echo "landing page missing"; docker logs caddy | tail; exit 1; }
curl -sf -H 'Host: signalk.elemental.internal' http://localhost/signalk | grep -q endpoints || { echo "Caddy -> SignalK proxy failed"; exit 1; }

echo "==> send PGN 128267 (water depth) frames until a point reaches InfluxDB"
FOUND=0
for i in $(seq 1 90); do
    cansend can0 09F50B00#00640000000000FF || true
    n="$(curl -sf -H "Authorization: Token $TOKEN" -H 'Content-Type: application/vnd.flux' -H 'Accept: application/csv' \
        "http://localhost:8086/api/v2/query?org=Smoke" \
        --data-binary 'from(bucket:"smoke_data") |> range(start:-10m) |> filter(fn:(r)=> r._measurement=="instruments") |> limit(n:1)' \
        | grep -c -E '^,_result' || true)"
    if [[ "${n:-0}" -gt 0 ]]; then FOUND=1; echo "    point arrived after ~${i}s"; break; fi
    sleep 1
done
if [[ $FOUND -ne 1 ]]; then
    echo "FAIL: no point reached InfluxDB"
    echo "--- [marine]/plugin/influx lines from signalk log"
    docker logs signalk 2>&1 | grep -v 'GET /signalk' | grep -i -E 'marine|influx|plugin|can|nmea|error|warn|provider' | head -80 || true
    echo "--- settings.json in the volume (pipedProviders)"
    docker exec signalk sh -c 'cat /home/node/.signalk/settings.json' 2>&1 | head -40 || true
    echo "--- plugin config in the volume"
    docker exec signalk sh -c 'cat /home/node/.signalk/plugin-config-data/signalk-to-influxdb2.json' 2>&1 | sed -E 's/("token": *")[^"]*/\1***/' | head -40 || true
    echo "--- CAN traffic seen on the host"
    timeout 3 candump can0 2>&1 | head -5 || true
    echo "--- SignalK data model: depth"
    curl -s http://localhost:3000/signalk/v1/api/vessels/self/environment 2>&1 | head -c 600 || true; echo
    echo "--- interface inside the signalk container"
    docker exec signalk ip -br link show 2>&1 | head || true
    exit 1
fi
echo "SMOKE TEST PASSED"
