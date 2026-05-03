#!/usr/bin/env bash
set -euo pipefail

# Switch the SignalK CAN bus interface between can0 and vcan0.
# Updates the persistent settings.json and restarts the container.

CONTAINER="signalk"
SETTINGS="/home/node/.signalk/settings.json"

# ── Prompt ──────────────────────────────────────────────────────────────────

echo "Select CAN interface for SignalK:"
echo "  1) can0   — real NMEA 2000 bus (production)"
echo "  2) vcan0  — virtual CAN (testing)"
echo ""
read -rp "Enter 1 or 2: " choice

case "$choice" in
    1) IFACE="can0" ;;
    2) IFACE="vcan0" ;;
    *)
        echo "Invalid selection '$choice' — must be 1 or 2." >&2
        exit 1
        ;;
esac

echo ""

# ── vcan0 prerequisite check ─────────────────────────────────────────────────

if [ "$IFACE" = "vcan0" ]; then
    if ip link show vcan0 2>/dev/null | grep -q "<.*UP.*>"; then
        echo "vcan0 is up."
    else
        echo "vcan0 is not up."
        read -rp "Set it up now? (requires sudo) [y/N]: " ans
        case "$ans" in
            y|Y)
                echo "Loading vcan kernel module..."
                sudo modprobe vcan
                if ! ip link show vcan0 2>/dev/null | grep -q "vcan0"; then
                    echo "Adding vcan0 interface..."
                    sudo ip link add dev vcan0 type vcan
                fi
                echo "Bringing vcan0 up..."
                sudo ip link set up vcan0
                echo "vcan0 is up."
                ;;
            *)
                echo "Proceeding without vcan0 setup — frames may not be received." >&2
                ;;
        esac
    fi
fi

echo "Switching SignalK to interface: $IFACE"

# ── Validate container is running ────────────────────────────────────────────

if ! docker inspect "$CONTAINER" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
    echo "ERROR: Container '$CONTAINER' is not running." >&2
    exit 1
fi

# ── Update settings.json ─────────────────────────────────────────────────────

docker exec "$CONTAINER" python3 -c "
import json, sys
path = '$SETTINGS'
try:
    with open(path) as f:
        s = json.load(f)
except Exception as e:
    print(f'ERROR reading {path}: {e}', file=sys.stderr)
    sys.exit(1)

providers = s.get('pipedProviders', [])
updated = 0
for p in providers:
    for el in p.get('pipeElements', []):
        opts = el.get('options', {})
        sub = opts.get('subOptions', {})
        if sub.get('type') == 'canbus':
            sub['interface'] = '$IFACE'
            updated += 1

if updated == 0:
    print('WARNING: no canbus provider found in settings — nothing changed', file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    json.dump(s, f, indent=2)
print(f'Updated {updated} provider(s) to interface: \$IFACE')
"

# ── Restart container ─────────────────────────────────────────────────────────

echo "Restarting SignalK container..."
docker restart "$CONTAINER" > /dev/null

echo ""
echo "Done. Waiting 15s for SignalK to come up..."
sleep 15

# ── Confirm ───────────────────────────────────────────────────────────────────

echo ""
RUNNING=$(docker inspect "$CONTAINER" --format '{{.State.Running}}' 2>/dev/null || echo false)
if [ "$RUNNING" = "true" ]; then
    echo "SignalK is running on interface: $IFACE"
    docker logs "$CONTAINER" 2>&1 | grep -E "candump|Connected to analyzer|exited" | tail -5
else
    echo "WARNING: SignalK container is not running — check: docker logs $CONTAINER" >&2
fi

# ── Test prompts ──────────────────────────────────────────────────────────────

if [ "$IFACE" = "vcan0" ]; then
    echo ""
    echo "────────────────────────────────────────────────────────────────────"
    echo "Test frames — run in a separate terminal:"
    echo ""
    echo "  # Water depth 1.0 m  (PGN 128267)"
    echo "  cansend vcan0 09F50B00#0064000000000000"
    echo ""
    echo "  # Speed through water ~5 knots  (PGN 128259)"
    echo "  cansend vcan0 09F50300#000101FFFFFFFFFF"
    echo ""
    echo "  # Vessel heading 90° true  (PGN 127250)"
    echo "  cansend vcan0 09F11200#005C3DFF7FFF7F00"
    echo ""
    echo "Verify in SignalK:"
    echo "  http://localhost:3000/signalk/v1/api/vessels/self/environment/depth/belowKeel"
    echo "  http://localhost:3000/signalk/v1/api/vessels/self/navigation/speedThroughWater"
    echo "  http://localhost:3000/signalk/v1/api/vessels/self/navigation/headingTrue"
    echo "────────────────────────────────────────────────────────────────────"
fi
