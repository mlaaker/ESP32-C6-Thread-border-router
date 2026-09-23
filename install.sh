#!/usr/bin/env bash
#
# Build, flash and join a Seeed XIAO ESP32-C6 to your Home Assistant Thread network
# as an extra Thread border router. See README.md.
#
# ============================== YOUR SETTINGS ==============================
# Edit these values, save, then run:  ./install.sh

# Wi-Fi network the border router connects to. Must be 2.4 GHz, and on the SAME network
# (subnet/VLAN) as Home Assistant, with IPv6 and mDNS allowed.
WIFI_SSID="My Home WiFi"

# Leave blank to be asked when you run the script (recommended, so it isn't saved in this file).
WIFI_PASSWORD=""

# Name shown in Home Assistant → Settings → Devices & services → Thread.
BORDER_ROUTER_NAME="Backyard Studio OpenThread Border Router"

# Network name: the device will answer at <this>.local. Lowercase letters, digits and hyphens only.
MDNS_HOSTNAME="backyard-studio-otbr"

# Home Assistant's Thread dataset (a long hex string). Leave blank to be asked.
# Get it from HA → Settings → Devices & services → Thread → (i) next to your network → copy the
# "Active operational dataset TLVs". It contains your network key, so treat it like a password.
THREAD_DATASET=""

# USB serial port of the XIAO. Leave blank to auto-detect (works when it's the only one plugged in).
# macOS looks like /dev/cu.usbmodem1101, Linux like /dev/ttyACM0.
SERIAL_PORT=""

# ESP-IDF activation script. Leave blank to auto-detect ~/.espressif/tools/activate_idf_v5.5*.sh.
IDF_ACTIVATE_SCRIPT=""

# ============================ END OF SETTINGS ==============================

set -eo pipefail

usage() {
    cat <<EOF
Usage: ./install.sh [step]

  all     build, flash, then join the Thread network (default)
  build   build the firmware only
  flash   flash the last build to the device
  join    join the Thread network (device already flashed) and report status
  status  report the device's Thread status without changing anything
EOF
}

STEP="${1:-all}"
case "$STEP" in all|build|flash|join|status) ;; -h|--help|help) usage; exit 0 ;; *) usage; exit 1 ;; esac

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW_DIR="$REPO_DIR/firmware"
IDF_DEFAULTS="sdkconfig.defaults;sdkconfig.user"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# --- ESP-IDF ---------------------------------------------------------------
activate_idf() {
    # Already activated in this terminal (EIM or classic export.sh)? Otherwise load EIM's activation script.
    if [ -z "$IDF_PATH" ] || [ ! -f "$IDF_PATH/tools/idf.py" ]; then
        if [ -z "$IDF_ACTIVATE_SCRIPT" ]; then
            IDF_ACTIVATE_SCRIPT="$(ls "$HOME"/.espressif/tools/activate_idf_v5.5*.sh 2>/dev/null | tail -1 || true)"
        fi
        [ -n "$IDF_ACTIVATE_SCRIPT" ] && [ -f "$IDF_ACTIVATE_SCRIPT" ] ||
            die "ESP-IDF v5.5 not found. Install it (README step 2) or set IDF_ACTIVATE_SCRIPT at the top of this file."
        # EIM's script refuses to be sourced from inside another script; its -e mode prints the variables instead.
        local key val
        while IFS= read -r line; do
            key="${line%%=*}"; val="${line#*=}"
            case "$key" in
                PATH) export PATH="$val:$PATH" ;;
                SYSTEM_PATH) ;;
                [A-Z_]*) export "$key=$val" ;;
            esac
        done < <(bash "$IDF_ACTIVATE_SCRIPT" -e)
    fi
    [ -f "$IDF_PATH/tools/idf.py" ] || die "Could not load ESP-IDF from ${IDF_ACTIVATE_SCRIPT:-your environment}."
    IDF_PYTHON="${IDF_PYTHON_ENV_PATH:+$IDF_PYTHON_ENV_PATH/bin/}python"
    local ver
    ver="$(idf_py --version 2>/dev/null || true)"
    case "$ver" in
        *v5.5*) echo "Using $ver" ;;
        *) die "Expected ESP-IDF v5.5.x, found '${ver:-nothing}'. This firmware is written against v5.5." ;;
    esac
}

idf_py() { "$IDF_PYTHON" "$IDF_PATH/tools/idf.py" "$@"; }

# --- Serial port -----------------------------------------------------------
find_port() {
    if [ -n "$SERIAL_PORT" ]; then
        [ -e "$SERIAL_PORT" ] || die "SERIAL_PORT $SERIAL_PORT does not exist. Is the XIAO plugged in with a data (not charge-only) cable?"
        return
    fi
    local ports
    ports="$(ls /dev/cu.usbmodem* /dev/ttyACM* 2>/dev/null || true)"
    local count
    count="$(printf '%s' "$ports" | grep -c . || true)"
    if [ "$count" = "1" ]; then
        SERIAL_PORT="$ports"
        echo "Found device on $SERIAL_PORT"
    elif [ "$count" = "0" ]; then
        die "No USB serial device found. Plug in the XIAO with a data cable (some USB-C cables are charge-only)."
    else
        printf 'Several serial ports found:\n%s\n' "$ports"
        die "Set SERIAL_PORT at the top of this file. To tell which is the XIAO, unplug it, run 'ls /dev/cu.usbmodem*', plug it back in and run it again."
    fi
}

# --- Settings checks -------------------------------------------------------
check_build_settings() {
    [ -n "$WIFI_SSID" ] && [ "$WIFI_SSID" != "My Home WiFi" ] || die "Set WIFI_SSID at the top of this file."
    [ -n "$BORDER_ROUTER_NAME" ] || die "Set BORDER_ROUTER_NAME at the top of this file."
    [ "${#BORDER_ROUTER_NAME}" -le 63 ] || die "BORDER_ROUTER_NAME must be 63 characters or fewer."
    [[ "$MDNS_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
        die "MDNS_HOSTNAME must be lowercase letters, digits and hyphens (e.g. backyard-studio-otbr)."
    if [ -z "$WIFI_PASSWORD" ]; then
        read -rsp "Wi-Fi password for \"$WIFI_SSID\": " WIFI_PASSWORD; echo
        [ -n "$WIFI_PASSWORD" ] || die "Wi-Fi password is empty."
    fi
}

check_dataset() {
    if [ -z "$THREAD_DATASET" ]; then
        echo "Paste Home Assistant's Thread dataset (HA → Settings → Devices & services → Thread → (i) → Active operational dataset TLVs):"
        read -r THREAD_DATASET
    fi
    THREAD_DATASET="$(printf '%s' "$THREAD_DATASET" | tr -d '[:space:]' | tr 'A-F' 'a-f')"
    [[ "$THREAD_DATASET" =~ ^([0-9a-f]{2})+$ ]] || die "THREAD_DATASET must be a hex string (letters a-f and digits only)."
}

# Escape a value for a Kconfig string: backslash and double quote.
kconfig_str() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; }

# --- Steps -----------------------------------------------------------------
do_build() {
    check_build_settings
    say "Writing your settings to firmware/sdkconfig.user"
    umask 077
    {
        echo "CONFIG_EXAMPLE_WIFI_SSID=$(kconfig_str "$WIFI_SSID")"
        echo "CONFIG_EXAMPLE_WIFI_PASSWORD=$(kconfig_str "$WIFI_PASSWORD")"
        echo "CONFIG_OTBR_INSTANCE_NAME=$(kconfig_str "$BORDER_ROUTER_NAME")"
        echo "CONFIG_OTBR_HOSTNAME=$(kconfig_str "$MDNS_HOSTNAME")"
    } > "$FW_DIR/sdkconfig.user"

    say "Building firmware (first build takes a few minutes)"
    cd "$FW_DIR"
    rm -f sdkconfig
    idf_py -D SDKCONFIG_DEFAULTS="$IDF_DEFAULTS" set-target esp32c6
    idf_py -D SDKCONFIG_DEFAULTS="$IDF_DEFAULTS" build
    grep -q '^CONFIG_OPENTHREAD_RADIO_NATIVE=y' sdkconfig && grep -q '^CONFIG_OPENTHREAD_RADIO_TREL=y' sdkconfig ||
        die "Build config is missing native radio or TREL; delete firmware/build and try again."
}

do_flash() {
    [ -f "$FW_DIR/build/esp_ot_br.bin" ] || die "No firmware built yet. Run ./install.sh build first."
    find_port
    say "Flashing $SERIAL_PORT (esptool stops here if the chip is not an ESP32-C6)"
    cd "$FW_DIR"
    idf_py -D SDKCONFIG_DEFAULTS="$IDF_DEFAULTS" -p "$SERIAL_PORT" flash
}

do_join() {
    check_dataset
    find_port
    say "Joining the Thread network (the device restarts when the port opens; this takes 1-3 minutes)"
    "$IDF_PYTHON" "$REPO_DIR/tools/provision.py" --port "$SERIAL_PORT" --dataset "$THREAD_DATASET"
}

do_status() {
    find_port
    "$IDF_PYTHON" "$REPO_DIR/tools/provision.py" --port "$SERIAL_PORT"
}

activate_idf
case "$STEP" in
    all)    check_dataset; do_build; do_flash; do_join ;;
    build)  do_build ;;
    flash)  do_flash ;;
    join)   do_join ;;
    status) do_status ;;
esac
