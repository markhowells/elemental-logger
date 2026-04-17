#!/bin/sh

DEFAULTS="/home/node/.signalk-defaults"
DATA="/home/node/.signalk"

# Seed configs on first run only
if [ ! -f "$DATA/settings.json" ]; then
    echo "[marine] First run: seeding settings.json"
    cp "$DEFAULTS/settings.json" "$DATA/settings.json"
fi
if [ ! -f "$DATA/plugin-config-data/signalk-to-influxdb2.json" ]; then
    echo "[marine] First run: seeding InfluxDB plugin config"
    mkdir -p "$DATA/plugin-config-data"
    cp "$DEFAULTS/plugin-config-data/signalk-to-influxdb2.json" \
        "$DATA/plugin-config-data/signalk-to-influxdb2.json"
fi

# Always sync the compiled plugin from the image into the volume so that
# image rebuilds (plugin updates) are always reflected at runtime.
echo "[marine] Syncing signalk-to-influxdb2 plugin"
mkdir -p "$DATA/node_modules"
rm -rf "$DATA/node_modules/signalk-to-influxdb2"
cp -r "$DEFAULTS/node_modules/signalk-to-influxdb2" \
    "$DATA/node_modules/signalk-to-influxdb2"

# ── One-time service init ───────────────────────────────────────────────────
# Run D-Bus / Avahi once so they survive SignalK restarts and don't add
# 40+ seconds to every restart cycle.
if [ -S /run/dbus/system_bus_socket ] && \
   dbus-send --system --dest=org.freedesktop.DBus --print-reply \
   /org/freedesktop/DBus org.freedesktop.DBus.ListNames >/dev/null 2>&1; then
    echo "[marine] Using host D-Bus"
else
    echo "[marine] Starting D-Bus and Avahi"
    service dbus restart
    /usr/sbin/avahi-daemon -k 2>/dev/null
    /usr/sbin/avahi-daemon --no-drop-root &
    service bluetooth restart
fi

export IS_IN_DOCKER=true
export CONTAINER_RUNTIME=docker

# ── Helpers ─────────────────────────────────────────────────────────────────

kill_all() {
    echo "[marine] Killing SignalK"
    pkill -9 -P "$1" 2>/dev/null || true
    kill -9 "$1" 2>/dev/null || true
    pkill -9 -f signalk-server 2>/dev/null || true
    sleep 2
}

# Returns 0 if SignalK HTTP endpoint is responding
signalk_ok() {
    node -e "
const h=require('http');
const r=h.get('http://127.0.0.1:3000/signalk',res=>{process.exit(res.statusCode<500?0:1)});
r.setTimeout(3000,()=>{r.destroy();process.exit(1)});
r.on('error',()=>process.exit(1));" 2>/dev/null
}

# PID 1 ignores SIGTERM by default — handle it explicitly
SIGNALK_PID=0
trap 'echo "[marine] Caught stop signal"; kill_all "$SIGNALK_PID"; exit 0' TERM INT

# ── Restart loop ─────────────────────────────────────────────────────────────
# Runs signalk-server directly (not via startup.sh) so Avahi/D-Bus are not
# reinitialised on every restart.
while true; do
    echo "[marine] Starting SignalK"
    /home/node/signalk/node_modules/signalk-server/bin/signalk-server \
        --securityenabled &
    SIGNALK_PID=$!

    # Wait up to 90s for SignalK to respond over HTTP
    WAIT=0
    READY=0
    while [ $WAIT -lt 90 ]; do
        sleep 2
        WAIT=$((WAIT + 2))
        if ! kill -0 "$SIGNALK_PID" 2>/dev/null; then
            echo "[marine] SignalK exited during startup"
            break
        fi
        if signalk_ok; then
            READY=1
            break
        fi
    done

    if [ $READY -eq 0 ]; then
        echo "[marine] Timed out waiting for SignalK — restarting in 3s"
        kill_all "$SIGNALK_PID"
        sleep 3
        continue
    fi

    echo "[marine] SignalK up and responding"

    # Watchdog: HTTP health check every 5s.
    # Catches both clean exit and a stuck server with the port still bound
    # (which is what happens after SignalK's own restart mechanism runs).
    while kill -0 "$SIGNALK_PID" 2>/dev/null; do
        sleep 5
        if ! signalk_ok; then
            echo "[marine] SignalK not responding — restarting"
            kill_all "$SIGNALK_PID"
            break
        fi
    done

    echo "[marine] Restarting in 3s"
    sleep 3
done
