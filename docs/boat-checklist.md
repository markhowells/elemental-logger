# Pi boat-trip checklist

Background: the Pi 4 has no RTC and no `fake-hwclock`, so offline boots start from the last time `systemd-timesyncd` synced (last seen 2026-05-09 ~19:50 UTC). The journal is also volatile, so a boot that fails early leaves no trace. This checklist makes the next trip leave evidence.

## Before leaving the bench (Pi online, SSH in)

> `deploy/install.sh` now does steps 1–2 for you (persistent journal, `fake-hwclock`), and `sudo marine-doctor`
> reports on them (steps 3–4 and the clock/journal/power checks). The manual commands below are kept for reference
> and for Pis installed before this change.

1. **Make the journal persistent.** This lets kernel and power messages survive a reboot:
   ```bash
   sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald
   ```
2. **Fix the clock so offline boots stop restarting from May 9.** Pick one:
   - **Cheap:**
     ```bash
     sudo apt install fake-hwclock
     ```
     It saves the time hourly and at shutdown, so offline boots start near the last real time. It is still wrong by however long the Pi was off, but not by months.
   - **Proper:** fit a DS3231 RTC on I²C.
     - Add `dtoverlay=i2c-rtc,ds3231` to `/boot/firmware/config.txt`.
     - Run `sudo apt purge fake-hwclock` and `sudo apt install util-linux-extra`.
     - After a reboot, run `sudo hwclock -w` while NTP is synced.
3. **Check the clock is synced** with `timedatectl`. It should say `System clock synchronized: yes`.
4. **Reboot once on the bench** and check the evidence survived with `journalctl --list-boots`. You should see two boots.
5. **Optional, separate fix:** make the SignalK plugin config match the repo (`Elemental/sailing_data` live vs `marine/signalk` in the template), so there is one destination for the data.

## On the boat (power on)

1. **Power the Pi from the boat supply and watch the LEDs for 60 seconds.**
   - **Green ACT LED:** flickering for 20–30 s means it is reading the SD card and booting. A dead green LED means it never started.
   - **Red PWR LED:** it should stay solid. If it flickers or dips, the 5 V is sagging.
2. **If you have a multimeter, measure the 5 V at the Pi's USB-C input while it boots.** Dipping below about 4.75 V is the likely cause.
3. **Try the Pi on a known-good supply at the same spot**, if you can. A proper 5 V / 3 A supply on a 12 V-to-USB adapter or the boat's own socket tells you whether the boat wiring is the issue.
4. **Check the connections.** Look at the fuse, polarity, the buck converter's output and the USB-C cable.
5. **If it boots,** connect to its Wi-Fi AP (`10.42.0.1`) and check that SignalK shows data. Screenshot it with the date visible, so you have a record.

## After the trip (back on the bench, Pi online)

```bash
sudo marine-doctor                  # one-shot summary: drift, services, bucket + recent data, clock, journal, power
vcgencmd get_throttled              # 0x0 = clean; bit 0 (0x1) = undervoltage now; bit 16 (0x10000) = undervoltage occurred since boot
journalctl --list-boots             # one line per boot: confirms the Pi booted on the boat
journalctl -b -1 | grep -i -E "under-voltage|voltage|brown"
journalctl -b -1 | head -50         # how far the boat boot got
timedatectl                         # was the clock near real time?
docker ps -a --format '{{.Names}} {{.Status}}'
```

### How to read the results

| What you see | What it means |
|---|---|
| No boat boot in `--list-boots` | It never got through boot. Suspect power: fuse, polarity, supply sag. |
| Boot present, `Under-voltage detected` | Power sags under load. Replace the supply or cable, or add a better buck converter. |
| Boot present, no power messages, but no Influx data | The boot worked and the problem is in the stack. Check `docker logs` and the plugin config. |
| Boot present, timestamps near May 9 | The clock was stale. Data is stamped in the past, so query that date range. |
