#!/usr/bin/env bash
# Interactive installer for the GPS/PPS disciplined Stratum-1 NTP server
# described in https://github.com/domschl/RaspberryNtpServer
#
# Tested target: Raspberry Pi OS 'Bookworm'/'Trixie' on Raspberry Pi 3/4/5.
# Run as root (sudo ./install.sh) on the Raspberry Pi itself.
# The optional LCD display software is fetched from the upstream repository
# (https://github.com/domschl/RaspberryNtpServer) if not present locally.
#
# The script is idempotent: it can be re-run safely, it only appends config
# lines that are not already present, and it backs up every file it edits
# with a .bak-<timestamp> suffix before the first change.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d%H%M%S)"
REBOOT_REQUIRED=0

# ---------- helpers ----------------------------------------------------

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Please run as root: sudo $0"
}

# ask_choice "Prompt" default_index "opt1" "opt2" ... -> sets REPLY_CHOICE (1-based index)
ask_choice() {
    local prompt="$1"; shift
    local default="$1"; shift
    local -a opts=("$@")
    local i
    echo "$prompt"
    for i in "${!opts[@]}"; do
        printf '  %d) %s\n' "$((i+1))" "${opts[$i]}"
    done
    local ans
    read -r -p "Choice [${default}]: " ans
    ans="${ans:-$default}"
    if ! [[ "$ans" =~ ^[0-9]+$ ]] || [ "$ans" -lt 1 ] || [ "$ans" -gt "${#opts[@]}" ]; then
        warn "Invalid choice, using default ($default)."
        ans="$default"
    fi
    REPLY_CHOICE="$ans"
}

# ask_value "Prompt" "default" -> sets REPLY_VALUE
ask_value() {
    local prompt="$1" default="$2" ans
    read -r -p "$prompt [$default]: " ans
    REPLY_VALUE="${ans:-$default}"
}

# ask_yn "Prompt" default(y|n) -> returns 0 for yes, 1 for no
ask_yn() {
    local prompt="$1" default="$2" ans
    local hint="y/N"; [ "$default" = "y" ] && hint="Y/n"
    read -r -p "$prompt [$hint]: " ans
    ans="${ans:-$default}"
    [[ "$ans" =~ ^[Yy] ]]
}

backup_once() {
    local f="$1"
    [ -f "$f" ] || return 0
    local marker="${f}.bak-${TS}"
    [ -f "$marker" ] || cp -a "$f" "$marker"
}

# append_line_if_missing <file> <exact line>
append_line_if_missing() {
    local file="$1" line="$2"
    touch "$file"
    grep -qxF "$line" "$file" 2>/dev/null || { backup_once "$file"; echo "$line" >> "$file"; }
}

CONFIG_TXT=""
find_config_txt() {
    if [ -f /boot/firmware/config.txt ]; then
        CONFIG_TXT=/boot/firmware/config.txt
    elif [ -f /boot/config.txt ]; then
        CONFIG_TXT=/boot/config.txt
    else
        die "Could not find config.txt under /boot/firmware or /boot."
    fi
}

CHRONY_CONF=""
find_chrony_conf() {
    if [ -f /etc/chrony/chrony.conf ]; then
        CHRONY_CONF=/etc/chrony/chrony.conf
    elif [ -f /etc/chrony.conf ]; then
        CHRONY_CONF=/etc/chrony.conf
    else
        die "chrony.conf not found - is chrony installed? (should have been installed by this script)"
    fi
}

pi_model() {
    tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "unknown"
}

is_pi3() {
    pi_model | grep -qi "Pi 3"
}

# ---------- start --------------------------------------------------------

require_root
find_config_txt

MODEL="$(pi_model)"
OS_CODENAME="$( . /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-unknown}" )"

log "Detected: ${MODEL} running Raspberry Pi OS '${OS_CODENAME}'"
log "config.txt found at: ${CONFIG_TXT}"

if ! is_pi3 && ! pi_model | grep -qiE "Pi 4|Pi 5"; then
    warn "This script was written for Raspberry Pi 3/4/5. Detected: ${MODEL}. Continuing anyway."
fi

echo
echo "This script will configure gpsd, PPS and chrony for a GPS-disciplined"
echo "Stratum-1 NTP server, following https://github.com/domschl/RaspberryNtpServer"
echo "It edits system files (backups are kept alongside originals as .bak-${TS})."
ask_yn "Continue?" y || { echo "Aborted."; exit 0; }

# ---------- 1. GPS connection type ---------------------------------------

log "Step 1/8: GPS module connection"
ask_choice "How is the GPS module connected?" 1 \
    "USB (module has its own USB serial adapter, e.g. Keystudio GPS module)" \
    "Serial / UART (wired to GPIO 14/15, e.g. Adafruit GPS Hat, bare NEO-6 module)"
CONN_TYPE="$REPLY_CHOICE"

GPS_DEVICE=""
USBAUTO="false"

if [ "$CONN_TYPE" = "1" ]; then
    USBAUTO="true"
    echo "Detected USB-serial devices:"
    mapfile -t usb_devs < <(ls /dev/ttyACM* /dev/ttyUSB* 2>/dev/null || true)
    if [ "${#usb_devs[@]}" -eq 0 ]; then
        warn "No /dev/ttyACM*/ttyUSB* device found yet (plug in the GPS module if not done)."
        ask_value "Enter the device path to use" "/dev/ttyACM0"
        GPS_DEVICE="$REPLY_VALUE"
    else
        usb_devs+=("Other / type manually")
        ask_choice "Select the GPS device" 1 "${usb_devs[@]}"
        if [ "$REPLY_CHOICE" -le "${#usb_devs[@]}" ] && [ "${usb_devs[$((REPLY_CHOICE-1))]}" != "Other / type manually" ]; then
            GPS_DEVICE="${usb_devs[$((REPLY_CHOICE-1))]}"
        else
            ask_value "Enter the device path to use" "/dev/ttyACM0"
            GPS_DEVICE="$REPLY_VALUE"
        fi
    fi
else
    USBAUTO="false"
    ask_choice "Select the serial device" 1 "/dev/ttyS0" "/dev/ttyAMA0" "Other / type manually"
    case "$REPLY_CHOICE" in
        1) GPS_DEVICE="/dev/ttyS0" ;;
        2) GPS_DEVICE="/dev/ttyAMA0" ;;
        *) ask_value "Enter the serial device path" "/dev/ttyS0"; GPS_DEVICE="$REPLY_VALUE" ;;
    esac

    log "Disabling serial console / enabling serial hardware (raspi-config)..."
    if command -v raspi-config >/dev/null; then
        raspi-config nonint do_serial_cons 1 || warn "do_serial_cons failed, continuing"
        raspi-config nonint do_serial_hw 0 || warn "do_serial_hw failed, continuing"
    else
        warn "raspi-config not found, skipping automatic serial console disable."
        warn "You may need to manually remove console=serial0/ttyAMA0 from ${CONFIG_TXT%/*}/cmdline.txt"
    fi

    if is_pi3; then
        log "Raspberry Pi 3 detected: freeing the PL011 UART from Bluetooth."
        append_line_if_missing "$CONFIG_TXT" "dtoverlay=pi3-disable-bt-overlay"
        systemctl disable --now hciuart 2>/dev/null || true
        REBOOT_REQUIRED=1
    fi
    REBOOT_REQUIRED=1
fi

log "GPS device: ${GPS_DEVICE} (USBAUTO=${USBAUTO})"

# ---------- 2. PPS setup --------------------------------------------------

log "Step 2/8: PPS (pulse-per-second) signal"
ask_value "GPIO pin the PPS signal is connected to" "4"
PPS_PIN="$REPLY_VALUE"

append_line_if_missing "$CONFIG_TXT" "dtoverlay=pps-gpio,gpiopin=${PPS_PIN}"
mkdir -p /etc/modules-load.d
append_line_if_missing /etc/modules-load.d/raspberrypi.conf "pps-gpio"
append_line_if_missing /etc/modules-load.d/raspberrypi.conf "pps-ldisc"
REBOOT_REQUIRED=1

# ---------- 3. Packages ---------------------------------------------------

log "Step 3/8: Installing gpsd, chrony, pps-tools..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y gpsd gpsd-clients pps-tools chrony >/dev/null

# ---------- 4. gpsd config -------------------------------------------------

log "Step 4/8: Configuring gpsd for device ${GPS_DEVICE}"
backup_once /etc/default/gpsd
cat > /etc/default/gpsd <<EOF
# Written by RaspberryNtpServer install.sh on $(date)
GPSD_OPTIONS="-n -G"
DEVICES="${GPS_DEVICE}"
USBAUTO="${USBAUTO}"
GPSD_SOCKET="/var/run/gpsd.sock"
START_DAEMON="true"
EOF

systemctl enable gpsd >/dev/null 2>&1 || true
systemctl restart gpsd || warn "gpsd failed to start - check 'systemctl status gpsd'"

# Disable systemd's own NTP client so it doesn't fight with chrony.
if systemctl list-unit-files | grep -q '^systemd-timesyncd'; then
    systemctl disable --now systemd-timesyncd 2>/dev/null || true
fi

# ---------- 5. chrony config ------------------------------------------------

log "Step 5/8: Configuring chrony"
find_chrony_conf
backup_once "$CHRONY_CONF"

ask_value "Initial GPS/PPS offset in seconds (tune later via 'chronyc sourcestats'; avoid exactly 0.0)" "0.005"
GPS_OFFSET="$REPLY_VALUE"

append_line_if_missing "$CHRONY_CONF" "refclock PPS /dev/pps0 lock GPS"
append_line_if_missing "$CHRONY_CONF" "refclock SHM 0 refid GPS precision 1e-1 offset ${GPS_OFFSET} delay 0.2 noselect"

ask_value "Local network to allow as NTP clients (CIDR, blank = localhost only)" ""
if [ -n "$REPLY_VALUE" ]; then
    append_line_if_missing "$CHRONY_CONF" "allow ${REPLY_VALUE}"
fi

# udev rule so chrony (running as its unprivileged user) can read /dev/pps0
CHRONY_GROUP="_chrony"
getent group _chrony >/dev/null 2>&1 || CHRONY_GROUP="chrony"
UDEV_RULE=/etc/udev/rules.d/pps-sources.rules
backup_once "$UDEV_RULE"
{
    echo "KERNEL==\"pps0\", OWNER=\"root\", GROUP=\"${CHRONY_GROUP}\", MODE=\"0660\""
    if [ "$CONN_TYPE" != "1" ]; then
        echo "KERNEL==\"$(basename "$GPS_DEVICE")\", RUN+=\"/bin/setserial -v ${GPS_DEVICE} low_latency irq 4\""
    fi
} > "$UDEV_RULE"
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true

systemctl enable chrony >/dev/null 2>&1 || systemctl enable chronyd >/dev/null 2>&1 || true
systemctl restart chrony 2>/dev/null || systemctl restart chronyd 2>/dev/null || warn "chrony failed to start - check 'systemctl status chrony'"

# ---------- 6. optional LCD display ----------------------------------------

log "Step 6/8: Optional 4x20 I2C status display (chronotron)"
if ask_yn "Install the optional LCD status display?" n; then
    if command -v raspi-config >/dev/null; then
        raspi-config nonint do_i2c 0 || warn "Could not enable I2C automatically, enable it manually via raspi-config."
    fi
    apt-get install -y python3-gps python3-smbus >/dev/null

    ask_choice "LCD adapter hardware" 1 \
        "Standard PCF8574 backpack (address 0x27)" \
        "Adafruit MCP23008 backpack (address 0x20)" \
        "Custom address / chip"
    case "$REPLY_CHOICE" in
        1) I2C_ADDR="0x27"; ADAFRUIT="False" ;;
        2) I2C_ADDR="0x20"; ADAFRUIT="True" ;;
        *)
            ask_value "I2C address (hex, e.g. 0x27)" "0x27"
            I2C_ADDR="$REPLY_VALUE"
            ask_yn "Is this an Adafruit MCP23008-based adapter?" n && ADAFRUIT="True" || ADAFRUIT="False"
            ;;
    esac

    if ask_yn "Keep the backlight on permanently (no night shutoff)?" n; then
        START_TIME="None"; END_TIME="None"
    else
        ask_value "Backlight on-time (HH:MM)" "07:00"; START_TIME="\"$REPLY_VALUE\""
        ask_value "Backlight off-time (HH:MM)" "21:00"; END_TIME="\"$REPLY_VALUE\""
    fi

    ask_yn "Display time in UTC instead of local time?" n && DISPLAY_UTC="True" || DISPLAY_UTC="False"
    ask_yn "Enable LCD latency overdrive (faster, out-of-spec refresh)?" n && LCD_OVERDRIVE="True" || LCD_OVERDRIVE="False"

    # The LCD software (chronotron) lives in the upstream repository.
    # Use a local ./src checkout if present, otherwise fetch upstream.
    LCD_SRC="${SCRIPT_DIR}/src"
    if [ ! -f "${LCD_SRC}/chronotron.py" ]; then
        log "Fetching LCD display software from upstream (domschl/RaspberryNtpServer)..."
        command -v git >/dev/null || apt-get install -y git >/dev/null
        TMP_CLONE="$(mktemp -d)"
        git clone --depth 1 https://github.com/domschl/RaspberryNtpServer.git "$TMP_CLONE" >/dev/null 2>&1 \
            || die "Could not clone the upstream repository (network down?)"
        LCD_SRC="${TMP_CLONE}/src"
    fi

    mkdir -p /opt/chronotron
    cp "${LCD_SRC}/button.py" "${LCD_SRC}/chronotron.py" "${LCD_SRC}/i2c_lcd.py" /opt/chronotron/
    chmod +x /opt/chronotron/chronotron.py

    TARGET=/opt/chronotron/chronotron.py
    sed -i \
        -e "s/^start_time:str|None = .*/start_time:str|None = ${START_TIME}/" \
        -e "s/^end_time:str|None = .*/end_time:str|None = ${END_TIME}/" \
        -e "s/^i2c_address_display:int = .*/i2c_address_display:int = ${I2C_ADDR}/" \
        -e "s/^adafruit_i2c_hardware:bool = .*/adafruit_i2c_hardware:bool = ${ADAFRUIT}/" \
        -e "s/^display_utc_time:bool = .*/display_utc_time:bool = ${DISPLAY_UTC}/" \
        -e "s/^lcd_latency_overdrive:bool = .*/lcd_latency_overdrive:bool = ${LCD_OVERDRIVE}/" \
        "$TARGET"

    cp "${LCD_SRC}/chronotron.service" /etc/systemd/system/chronotron.service
    # Use python3 explicitly - stock Raspberry Pi OS may not have a /usr/bin/python shebang target.
    sed -i "s#^ExecStart=.*#ExecStart=$(command -v python3) /opt/chronotron/chronotron.py#" /etc/systemd/system/chronotron.service
    systemctl daemon-reload
    systemctl enable --now chronotron

    log "LCD display installed. Check with: systemctl status chronotron"
else
    log "Skipping LCD display."
fi

# ---------- 7. gpstool status menu ------------------------------------------

log "Step 7/8: Installing 'gpstool' status menu to /usr/local/bin"
if [ -f "${SCRIPT_DIR}/gpstool" ]; then
    install -m 755 "${SCRIPT_DIR}/gpstool" /usr/local/bin/gpstool
    log "Installed. Type 'gpstool' for an interactive GPS/PPS/NTP status menu."
else
    warn "gpstool not found next to install.sh - skipping (copy it manually if needed)."
fi

# ---------- 8. optional Home Assistant status exporter -----------------------

log "Step 8/8: Optional Home Assistant status exporter"
echo "A small web service (port 9550) that publishes the server's health"
echo "(GPS fix, satellites, PPS lock, stratum) as JSON for Home Assistant's"
echo "'rest:' integration, plus a mini status web page. See README.md for"
echo "the ready-made Home Assistant YAML."
EXPORTER_INSTALLED=0
if ask_yn "Install the Home Assistant status exporter?" n; then
    if [ -f "${SCRIPT_DIR}/ha/ntp-status-exporter" ]; then
        install -m 755 "${SCRIPT_DIR}/ha/ntp-status-exporter" /usr/local/bin/ntp-status-exporter
        cp "${SCRIPT_DIR}/ha/ntp-status-exporter.service" /etc/systemd/system/
        # Run the exporter as the invoking (non-root) user, not necessarily 'pi'
        sed -i "s/^User=.*/User=${SUDO_USER:-pi}/" /etc/systemd/system/ntp-status-exporter.service
        systemctl daemon-reload
        systemctl enable --now ntp-status-exporter
        EXPORTER_INSTALLED=1
        PI_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
        log "Exporter running: http://${PI_IP:-<this-pi>}:9550/ (JSON at /status.json)"
    else
        warn "ha/ntp-status-exporter not found next to install.sh - skipping."
    fi
else
    log "Skipping Home Assistant exporter."
fi

# ---------- summary ----------------------------------------------------

log "Done."
echo "  GPS device      : ${GPS_DEVICE} (USB auto: ${USBAUTO})"
echo "  PPS GPIO pin    : ${PPS_PIN}"
echo "  chrony.conf     : ${CHRONY_CONF}"
echo
echo "Check status with:"
echo "  gpstool                  # interactive status menu (recommended)"
echo "  cgps                     # GPS fix"
echo "  sudo ppstest /dev/pps0   # PPS pulses (after reboot)"
echo "  chronyc sources          # NTP sources, look for #* PPS"
echo "  chronyc sourcestats      # tune the GPS offset in ${CHRONY_CONF} if PPS stays unusable"
if [ "$EXPORTER_INSTALLED" -eq 1 ]; then
    echo "  curl http://localhost:9550/status.json   # Home Assistant exporter"
fi

if [ "$REBOOT_REQUIRED" -eq 1 ]; then
    echo
    warn "A reboot is required for the serial/PPS device-tree changes to take effect."
    if ask_yn "Reboot now?" n; then
        reboot
    fi
fi
exit 0
