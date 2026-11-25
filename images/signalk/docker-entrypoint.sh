#!/bin/sh

# Ensure node binary is on PATH (the base image may install it via nvm,
# which only gets sourced in login shells — not in a Docker entrypoint).
if ! command -v node >/dev/null 2>&1; then
    _node=$(find /usr/local/bin /usr/bin /home/node /root -maxdepth 6 \
        -name node -type f -perm /u+x 2>/dev/null | head -1)
    if [ -n "$_node" ]; then
        _nodedir="$(dirname "$_node")"
        export PATH="$_nodedir:$PATH"
        echo "[marine] node found at $_node — added to PATH"
    else
        echo "[marine] ERROR: node binary not found — cannot start SignalK"
        exit 1
    fi
    unset _node
fi

DEFAULTS="/home/node/.signalk-defaults"
DATA="/home/node/.signalk"
# Managed (rendered) config, bind-mounted read-only by docker-compose.
MANAGED="/marine-config"

# ── Managed config ──────────────────────────────────────────────────────────
# The repo/release is the source of truth for these files, so they are applied
# on EVERY start (no more seed-once drift):
#   - plugin-config-data/signalk-to-influxdb2.json : overwritten
#   - settings.json : only the managed keys are merged (SignalK rewrites the
#     rest at runtime, see merge-settings.js and docs/config-model.md)
# Everything else in the volume (security.json, users, KIP history, resources)
# is preserved.
mkdir -p "$DATA/plugin-config-data"
if [ -d "$MANAGED" ]; then
    if [ -f "$MANAGED/plugin-config-data/signalk-to-influxdb2.json" ]; then
        if [ -f "$DATA/plugin-config-data/signalk-to-influxdb2.json" ] && \
           ! cmp -s "$MANAGED/plugin-config-data/signalk-to-influxdb2.json" \
                    "$DATA/plugin-config-data/signalk-to-influxdb2.json"; then
            echo "[marine] DRIFT: live InfluxDB plugin config differed from managed config — overwriting"
        fi
        cp "$MANAGED/plugin-config-data/signalk-to-influxdb2.json" \
           "$DATA/plugin-config-data/signalk-to-influxdb2.json"
        echo "[marine] Applied managed InfluxDB plugin config"
    else
        echo "[marine] WARNING: no managed plugin config in $MANAGED — keeping existing"
    fi
    if [ -f "$MANAGED/settings.managed.json" ]; then
        merge-settings "$MANAGED/settings.managed.json" "$DATA/settings.json" | sed 's/^/[marine] /'
    else
        echo "[marine] WARNING: no managed settings in $MANAGED — keeping existing"
    fi
else
    echo "[marine] WARNING: $MANAGED not mounted — running with whatever config is in the volume"
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

# Diagnose CAN prerequisites once at container start
if command -v candump2analyzer >/dev/null 2>&1; then
    echo "[marine] candump2analyzer: OK"
else
    echo "[marine] WARNING: candump2analyzer not found — CAN bus data will not flow"
fi
if ip link show can0 2>/dev/null | grep -q "state UP"; then
    echo "[marine] can0: UP"
else
    # Informational only: the host unit (marine-stack.service) waits for can0.
    # On a bench without a CAN interface this is expected.
    echo "[marine] NOTE: can0 is not UP — CAN bus data will not be received until it is"
fi

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
