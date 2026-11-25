#!/usr/bin/env bash
set -euo pipefail

# Switch the CAN interface SignalK reads between can0 (real NMEA 2000 bus) and vcan0 (virtual,
# for bench tests). It changes CAN_INTERFACE in /etc/marine/marine.env and runs marine-apply, so
# the choice is part of the managed config and survives container restarts (the old version edited
# settings.json inside the container, which marine-apply now owns).
#
# Usage: sudo tools/canswitch.sh [can0|vcan0]      (prompts if no argument)

ENV_FILE="${MARINE_ENV:-/etc/marine/marine.env}"

if [[ $EUID -ne 0 ]]; then echo "Run as root: sudo $0 $*" >&2; exit 1; fi
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found" >&2; exit 1; }

IFACE="${1:-}"
if [[ -z "$IFACE" ]]; then
    echo "Select CAN interface for SignalK:"
    echo "  1) can0   — real NMEA 2000 bus (production)"
    echo "  2) vcan0  — virtual CAN (testing)"
    echo ""
    read -rp "Enter 1 or 2: " choice
    case "$choice" in 1) IFACE=can0 ;; 2) IFACE=vcan0 ;; *) echo "Invalid selection '$choice' — must be 1 or 2." >&2; exit 1 ;; esac
fi
case "$IFACE" in can0|vcan0) ;; *) echo "Interface must be can0 or vcan0" >&2; exit 1 ;; esac

if [[ "$IFACE" == "vcan0" ]]; then
    modprobe vcan
    ip link show vcan0 >/dev/null 2>&1 || ip link add dev vcan0 type vcan
    ip link set up vcan0
    echo "vcan0 is up."
fi

# Set CAN_INTERFACE in marine.env (replace an existing line, commented or not, else append).
if grep -q -E '^#?CAN_INTERFACE=' "$ENV_FILE"; then
    sed -i -E "s|^#?CAN_INTERFACE=.*|CAN_INTERFACE=$IFACE|" "$ENV_FILE"
else
    printf '\nCAN_INTERFACE=%s\n' "$IFACE" >> "$ENV_FILE"
fi
echo "Switching SignalK to interface: $IFACE (marine-apply will restart SignalK)"
"$(dirname "$(readlink -f "$0")")/../deploy/marine-apply"

if [[ "$IFACE" == "vcan0" ]]; then
    cat <<MSG

────────────────────────────────────────────────────────────────────
TEST MODE: SignalK reads vcan0. marine-doctor will warn until you switch back:
    sudo tools/canswitch.sh can0

Test frames — run in a separate terminal:

  # Water depth 1.0 m  (PGN 128267)
  cansend vcan0 09F50B00#0064000000000000

  # Speed through water ~5 knots  (PGN 128259)
  cansend vcan0 09F50300#000101FFFFFFFFFF

  # Vessel heading 90° true  (PGN 127250)
  cansend vcan0 09F11200#005C3DFF7FFF7F00

Verify in SignalK:
  http://localhost:3000/signalk/v1/api/vessels/self/environment/depth/belowKeel
  http://localhost:3000/signalk/v1/api/vessels/self/navigation/speedThroughWater
  http://localhost:3000/signalk/v1/api/vessels/self/navigation/headingTrue
────────────────────────────────────────────────────────────────────
MSG
fi
