# Raspberry Pi Stratum-1 NTP Server — Interactive Installer

An interactive, idempotent installer that turns a Raspberry Pi with a GPS
module into a GPS/PPS-disciplined **Stratum-1 NTP server**, plus `gpstool`,
a small status menu for checking the server at a glance.

This project automates the excellent step-by-step guide by
**[domschl/RaspberryNtpServer](https://github.com/domschl/RaspberryNtpServer)** —
all credit for the original research, wiring diagrams and configuration
recipes goes there. Read that guide for hardware selection, wiring and
background; use this installer to skip the manual configuration work.

## What the installer does

Run `sudo ./install.sh` and answer a few questions — everything below is
handled automatically:

1. **GPS connection** — choose USB or serial/UART from a menu. USB devices
   (`/dev/ttyACM*`, `/dev/ttyUSB*`) are auto-detected and offered as a list;
   for serial connections the login console on the UART is disabled via
   `raspi-config` (and on a Pi 3 the PL011/Bluetooth conflict is resolved).
2. **PPS signal** — asks for the GPIO pin (default 4), adds the `pps-gpio`
   overlay to `config.txt` and the required kernel modules.
3. **Packages** — installs `gpsd`, `gpsd-clients`, `chrony`, `pps-tools`.
4. **gpsd** — writes `/etc/default/gpsd` for your device and starts the
   service; disables `systemd-timesyncd` so it doesn't fight with chrony.
5. **chrony** — adds the PPS and GPS refclocks, asks for the initial
   GPS offset and the client network to `allow`, and installs a udev rule
   so the unprivileged `_chrony` user can read `/dev/pps0`.
6. **Optional 4×20 I2C LCD display** — installs the upstream *chronotron*
   status display as a systemd service. Hardware is picked from a menu
   (standard PCF8574 @ 0x27 / Adafruit MCP23008 @ 0x20 / custom), backlight
   schedule and UTC display are configurable. The display software is
   fetched from the upstream repository automatically.
7. **gpstool** — installs the status menu to `/usr/local/bin/gpstool`.

Safety properties:

- **Idempotent** — safe to re-run; config lines are only appended when
  missing, so answering wrong once and re-running with the right answers
  simply fixes the system.
- **Backups** — every modified system file is backed up first as
  `<file>.bak-<timestamp>`.

## Requirements

- Raspberry Pi 3, 4 or 5 (the script detects the model and adapts).
- Raspberry Pi OS **Bookworm** or **Trixie** (64-bit recommended).
- A GPS module with a **PPS output** wired to a GPIO pin (default GPIO 4),
  connected via UART (GPIO 14/15) or USB, and an **active GPS antenna**
  with sky view. See the
  [upstream hardware guide](https://github.com/domschl/RaspberryNtpServer#requirements---hardware)
  for module recommendations and wiring diagrams.

## Usage

```bash
git clone https://github.com/aGGreSSiv/RaspberryNtpServer-installer.git
cd RaspberryNtpServer-installer
sudo ./install.sh
```

Answer the prompts, reboot when asked, then check the result:

```bash
gpstool
```

## gpstool

`gpstool` is a one-keystroke menu around the diagnostic commands from the
upstream guide:

```
======================================================
  gpstool - GPS / PPS / NTP server status menu
======================================================

  GPS
   1) cgps            - live GPS view: fix status, satellites in use,
                        signal strength, position (quit with 'q')
   2) gpsmon          - low-level GPS monitor with raw NMEA sentences

  PPS
   3) ppstest         - watch the pulse-per-second signal on /dev/pps0

  NTP / chrony
   4) chronyc tracking    - server stratum, reference source, precision
   5) chronyc sources     - all time sources; '#* PPS0' means stratum 1
   6) chronyc sourcestats - source statistics for offset tuning

  General
   7) service status  - systemd status of gpsd and chrony
   8) health summary  - one-shot overview: fix, satellites, PPS, stratum
```

The **health summary** answers "is everything working?" in one screen:

```
=== Quick health summary ===

GPS fix      : 3D FIX
Satellites   : 09 used / 12 seen
PPS signal   : OK (pulses arriving on /dev/pps0)
NTP stratum  : 1  (reference: 50505330 (PPS0))
Time source  : GPS PPS locked - server is running as STRATUM 1
Services     : gpsd=active chrony=active
```

It parses the raw NMEA stream rather than gpsd's SKY reports, so satellite
counts work in every state — even indoors without an antenna.

## Verifying stratum 1 after installation

Once the antenna has sky view and the GPS gets a fix:

1. `gpstool` → option 1 (`cgps`) should show **3D FIX**.
2. Option 3 (`ppstest`) should print one `assert` line per second.
3. Option 5 (`chronyc sources`) should show `#* PPS0` (locked).
4. Option 4 (`chronyc tracking`) should show `Stratum : 1`.

If PPS stays unusable (`#?`) although the fix is fine, tune the GPS offset:
run option 6 (`sourcestats`), read the `Offset` column of the GPS row,
write it (in seconds) into the `refclock SHM 0 ... offset <value>` line of
`/etc/chrony/chrony.conf` and restart chrony. Details in the
[upstream guide](https://github.com/domschl/RaspberryNtpServer#synchronizing-the-offset-between-serial-time-information-and-pps).

## Tested on

- Raspberry Pi 4 Model B Rev 1.4, Raspberry Pi OS **Trixie**
  (Debian 13, kernel 6.18, 64-bit)
- chrony 4.6.1, gpsd 3.25
- u-blox NEO-6 class GPS module on `/dev/ttyS0` (UART), PPS on GPIO 4

## Credits

- [Dominik Schlösser (domschl)](https://github.com/domschl) —
  [RaspberryNtpServer](https://github.com/domschl/RaspberryNtpServer), the
  guide this installer implements, and the *chronotron* LCD display
  software installed by step 6.

## License

MIT — see [LICENSE](LICENSE). The optional LCD display software fetched
from the upstream repository is licensed under the upstream project's
terms.
