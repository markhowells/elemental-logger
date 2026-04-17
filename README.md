# Marine Pi

Raspberry Pi setup for a sailing vessel. Turns the Pi into a WiFi access point and runs a Docker stack for instrument data logging.

## What it does

- Reads NMEA 2000 data from a CAN bus (`can0`)
- Serves vessel data via **SignalK** at `http://<pi-ip>:3000`
- Stores time-series data in **InfluxDB** at `http://<pi-ip>:8086`
- Manages containers via **Portainer** at `http://<pi-ip>:9000`
- Broadcasts a WiFi access point so phones/tablets can connect without a router

## Requirements

- Raspberry Pi running Debian (bookworm or trixie)
- CAN bus interface on `can0` (e.g. PiCAN2)
- Internet access during setup (to pull Docker images and the SignalK plugin)

## Setup

1. Clone this repo onto the Pi.

2. Edit `marine.conf` — replace every `changeme` value:

   ```bash
   nano marine.conf
   ```

   | Variable | Description |
   |---|---|
   | `WIFI_SSID` | Access point name |
   | `WIFI_PASSWORD` | WPA2 passphrase (8–63 chars) |
   | `WIFI_COUNTRY` | ISO 3166-1 alpha-2 country code (e.g. `GB`) |
   | `PORTAINER_ADMIN_PASSWORD` | Portainer admin password (12+ chars) |
   | `INFLUXDB_USERNAME` | InfluxDB admin username |
   | `INFLUXDB_PASSWORD` | InfluxDB admin password |
   | `INFLUXDB_TOKEN` | Operator token — generate with `openssl rand -hex 32` |
   | `INFLUXDB_ORG` | InfluxDB organisation name |
   | `INFLUXDB_BUCKET` | InfluxDB bucket name |
   | `VESSEL_NAME` | Vessel name (written into SignalK) |
   | `VESSEL_MMSI` | MMSI number (optional — leave blank if none) |

3. Run the setup script as root:

   ```bash
   sudo ./setup.sh
   ```

   This will install Docker, configure the WiFi AP, build the SignalK image, and start all services. Takes a few minutes on first run.

4. Log out and back in for Docker group membership to take effect.

## Accessing services

After setup, connect a device to the WiFi AP and open:

| Service | URL | Credentials |
|---|---|---|
| SignalK | `http://10.42.0.1:3000` | set in SignalK UI |
| InfluxDB | `http://10.42.0.1:8086` | `INFLUXDB_USERNAME` / `INFLUXDB_PASSWORD` |
| Portainer | `http://10.42.0.1:9000` | `admin` / `PORTAINER_ADMIN_PASSWORD` |

## Updating SignalK

After modifying `Dockerfile` or the plugin:

```bash
docker build -t marine-signalk:latest .
sudo systemctl restart marine-stack
```

## Logs

```bash
docker logs signalk
docker logs influxdb
docker logs portainer
```
