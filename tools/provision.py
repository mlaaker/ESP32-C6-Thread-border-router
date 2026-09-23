#!/usr/bin/env python3
"""Join the flashed XIAO ESP32-C6 to a Thread network over its USB serial console, then report status.

Run through ../install.sh (which puts ESP-IDF's Python, with pyserial, on PATH):
    ./install.sh join      # set the dataset if needed, wait for the router role
    ./install.sh status    # read-only

Opening the port restarts the XIAO. The dataset is saved on the device, so it rejoins on every boot by itself.
"""
import argparse
import re
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("pyserial is missing. Run this through ./install.sh so ESP-IDF's Python environment is used.")

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
BOOT_DONE = ("Resuming saved Thread network", "No saved Thread dataset")
ROLES = ("disabled", "detached", "child", "router", "leader")


class Device:
    def __init__(self, port, debug=False):
        self.debug = debug
        self.ser = serial.Serial()
        self.ser.port = port
        self.ser.baudrate = 115200
        self.ser.timeout = 0.2
        self.ser.dtr = False
        self.ser.rts = False
        self.ser.open()
        self.log = ""

    def restart(self):
        """Closing and reopening the USB-Serial/JTAG port restarts the ESP32-C6."""
        self.ser.close()
        time.sleep(1)
        self.ser.open()

    def read_for(self, seconds, until=None):
        end = time.time() + seconds
        buf = ""
        while time.time() < end:
            chunk = self.ser.read(4096).decode(errors="replace")
            if chunk:
                buf += ANSI.sub("", chunk)
                if until and any(u in buf for u in until):
                    break
        self.log += buf
        return buf

    def cmd(self, command, timeout=10):
        """Send an OpenThread CLI command and return its output lines. Raises on 'Error'.

        Background log lines are interleaved with the output and can be split mid-line, so callers look
        for exact values (e.g. a line that is only a role name) instead of trusting line order.
        """
        self.ser.reset_input_buffer()
        self.ser.write((command + "\r\n").encode())
        out = self.read_for(timeout, until=("\nDone", "Error "))
        if self.debug:
            print(f"--- raw output of {command!r} ---\n{out}\n---")
        lines = [line.strip().removeprefix("esp32c6>").removeprefix(">").strip() for line in out.splitlines()]
        errors = [line for line in lines if re.match(r"^Error \d+:", line)]
        if errors:
            raise RuntimeError(f"'{command}' failed: {errors[0]}")
        return [line for line in lines if line and line != command]

    def state(self):
        return next((l for l in self.cmd("ot state") if l in ROLES), "")

    def dataset_hex(self, expected=None, tries=3):
        """The saved dataset as hex, or "" if none. A log line can split the hex line, so read a few times
        and keep the longest; stop early if it matches `expected`."""
        best = ""
        for _ in range(tries):
            try:
                lines = self.cmd("ot dataset active -x")
            except RuntimeError:
                return ""  # Error 23: NotFound, no dataset saved
            best = max([best] + [l for l in lines if re.fullmatch(r"[0-9a-f]{20,}", l)], key=len)
            if expected and best == expected:
                break
            time.sleep(1)
        return best

    def wait_for_boot(self, seconds=60):
        boot = self.read_for(seconds, until=BOOT_DONE)
        return boot, any(m in boot for m in BOOT_DONE)


def dataset_fields(dev):
    fields = {}
    for line in dev.cmd("ot dataset active"):
        if ":" in line:
            key, _, value = line.partition(":")
            fields[key.strip()] = value.strip()
    return fields


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--dataset", help="Active operational dataset TLVs (hex). Omit for a read-only status check.")
    ap.add_argument("--timeout", type=int, default=240, help="seconds to wait for the router role")
    ap.add_argument("--debug", action="store_true", help="print raw CLI output")
    args = ap.parse_args()

    dev = Device(args.port, debug=args.debug)
    print("Waiting for the device to boot and connect to Wi-Fi...")
    boot, booted = dev.wait_for_boot()
    ip = re.search(r"IPv4 address: ([\d.]+)", boot)
    if not booted:
        hint = ""
        if "Connecting to" in boot and not ip:
            hint = (" It did not get an IP address: check WIFI_SSID / password, that the network is 2.4 GHz,"
                    " and that the device is in Wi-Fi range. Then run ./install.sh again.")
        sys.exit("The device did not finish starting within 60 s." + hint)
    print(f"Wi-Fi connected, IP address {ip.group(1) if ip else 'unknown'}")

    wanted = args.dataset.lower() if args.dataset else None
    current = dev.dataset_hex(expected=wanted)
    if wanted:
        if current == wanted:
            print("Thread dataset already saved on the device.")
        else:
            print("Saving the Thread dataset..." if not current else "Replacing the saved Thread dataset...")
            # `dataset set active <tlvs>` saves it directly. Don't follow it with `dataset commit active`:
            # that commits the (empty) scratch dataset and erases the one just saved.
            dev.cmd("ot thread stop")
            saved = False
            try:
                dev.cmd(f"ot dataset set active {wanted}")
                saved = dev.dataset_hex(expected=wanted) == wanted
            finally:
                # Always restart: Thread comes up the same way it will after every power cut (and it is
                # never left stopped if saving failed).
                print("Restarting the device...")
                dev.restart()
                boot, booted = dev.wait_for_boot()
            if not saved:
                sys.exit("The device did not accept the dataset. Check that you copied the whole string from Home Assistant.")
            if not booted:
                sys.exit("The device did not come back up after restarting. Unplug it, plug it back in and run ./install.sh status")
    elif not current:
        sys.exit("No Thread dataset saved on the device yet. Run ./install.sh join")

    print("Waiting for the device to join (up to %d s)..." % args.timeout)
    end = time.time() + args.timeout
    state = ""
    while time.time() < end:
        state = dev.state()
        print(f"  state: {state or '?'}")
        if state == "router":
            break
        time.sleep(10)

    fields = dataset_fields(dev)
    routers = [l for l in dev.cmd("ot neighbor table") if re.match(r"^\|\s+R\s+\|", l)]
    trel = [l for l in dev.cmd("ot trel peers") if re.match(r"^\|\s+\d", l)]
    xpan = fields.get("Ext PAN ID", "?")
    same_net_trel = [l for l in trel if xpan in l]

    print("\n---------------- Result ----------------")
    print(f"Thread network : {fields.get('Network Name', '?')}  (ext PAN ID {xpan}, channel {fields.get('Channel', '?')})")
    print(f"Role           : {state}")
    print(f"Router links   : {len(routers)}  (TREL peers on this network: {len(same_net_trel)})")

    if state == "router" and routers:
        print("\nSuccess. It should appear in HA → Settings → Devices & services → Thread within a few minutes.")
        return
    if state == "leader" and not routers:
        sys.exit("\nThe device formed its own separate Thread partition: it can't reach your Home Assistant border"
                 " router by radio or over the LAN. Check that it is on the same network/VLAN as Home Assistant"
                 " (IPv6 and mDNS must pass), and that the dataset came from the network HA marks as preferred.")
    sys.exit(f"\nNot joined yet (role: {state or 'unknown'}). Wait a minute and run ./install.sh status")


if __name__ == "__main__":
    main()
