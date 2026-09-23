# Extend your Home Assistant Thread network quickly, cheaply, and easily using a $5 Seeed XIAO ESP32-C6 device

[Matter](https://en.wikipedia.org/wiki/Matter_(standard)) promised a reliable cross-platform smart home standard, but has proven to be a bit more complicated. If you have Matter devices that use Thread networking but aren't close enough to a Thread 'border router,' you may find yourself flustered with how to get that device to connect to your smart home platform.

Turn a Seeed Studio XIAO ESP32-C6 into a second Thread border router that joins your **existing** Home
Assistant Thread network. Put it near Thread devices that are too far from your main border router,
such as those in a garage, barn, accessory dwelling unit (ADU), or detached building.

## Why you'd want one

Thread devices form a mesh, but only **mains-powered** devices relay traffic. Battery devices like door
sensors, buttons and leak sensors never relay. Wi-Fi Matter plugs don't relay Thread either, since they
have no Thread radio. So a battery sensor in an outbuilding often reaches Home Assistant over **one weak
radio link** through several walls. In HA's Matter Server Thread map, that link shows as orange or red,
and the device drops out or reacts slowly.

This board connects to your home Wi-Fi and links to Home Assistant's border router **over the LAN** using
TREL (Thread Radio Encapsulation Link). Nearby Thread devices then connect to it over a short radio hop,
so the distance to the house stops mattering.

It joins *your Home Assistant* Thread network. It doesn't create a new network or replace your main
border router, and nothing is sent to the cloud.

## What you need

- **[Seeed Studio XIAO ESP32-C6](https://m13.me/esp32c6)** (about $5)
- A **USB-C data cable**. Some cables only carry power; if no serial port appears, try another cable.
- Any USB power adapter to run it once installed.
- A **Mac** (these steps were tested on macOS) or a Linux PC.
- **Home Assistant with a working Thread border router** (e.g. Home Assistant Yellow, Connect ZBT-1 /
  SkyConnect with the OpenThread Border Router add-on) and at least one Thread network in
  *Settings → Devices & services → Thread*.
- **2.4 GHz Wi-Fi on the same network (subnet/VLAN) as Home Assistant**, with IPv6 and mDNS allowed.
  The ESP32-C6 has no 5 GHz radio. Don't put it on a separate IoT VLAN unless that VLAN carries IPv6 and mDNS
  to Home Assistant; HA finds border routers via mDNS on its own network.

## Setup

All commands run in Terminal (or free and amazing Terminal replacement [Warp](https://m13.me/trywarp)).

### 1. Download this project

```bash
git clone https://github.com/mlaaker/ESP32-C6-Thread-border-router.git
cd ESP32-C6-Thread-border-router
```

### 2. Install ESP-IDF v5.5 (Espressif's build tools, one time)

Use Espressif's Installation Manager (EIM). On macOS with [Homebrew](https://brew.sh):

```bash
brew install cmake dfu-util
brew tap espressif/eim
brew install eim
eim install -i v5.5.5
```

Prefer a GUI? `brew install --cask eim-gui`, then install **v5.5.5**. For Linux or other options see
[Espressif's EIM docs](https://docs.espressif.com/projects/idf-im-ui/en/latest/). The installer script
finds ESP-IDF in its default location (`~/.espressif`) on its own.

### 3. Copy your Thread network's dataset from Home Assistant

In HA: **Settings → Devices & services → Thread → Configure**. Next to the network marked *preferred*,
click **(i)** and copy the **Active operational dataset TLVs**, a long hex string. It includes your
Thread network key, so treat it like a password.

### 4. Enter your settings

Open `install.sh` in any text editor. The only part you edit is the **YOUR SETTINGS** block at the top:

| Setting | What to put there |
|---|---|
| `WIFI_SSID` | Your 2.4 GHz Wi-Fi network name (the same network as Home Assistant) |
| `WIFI_PASSWORD` | Leave blank and the script asks for it, so it isn't saved in the file |
| `BORDER_ROUTER_NAME` | The name Home Assistant shows, e.g. `Garage OpenThread Border Router` |
| `MDNS_HOSTNAME` | Its network name; the device answers at `<name>.local`, e.g. `garage-otbr` |
| `THREAD_DATASET` | Paste the dataset from step 3, or leave blank to be asked |
| `SERIAL_PORT` | Leave blank if the XIAO is the only USB serial device plugged in |

If you have other USB serial devices plugged in (other ESP boards, 3D printers, etc.), set
`SERIAL_PORT` so the wrong device is never flashed. To find it: unplug the XIAO, run
`ls /dev/cu.usbmodem*`, plug it back in, run it again. The new entry is the XIAO.

### 5. Build, flash and join

Plug in the XIAO and run:

```bash
./install.sh
```

The first build takes a few minutes. The script then flashes the board, saves the Thread dataset on it,
and waits for it to join. A successful run ends with:

```
Role           : router
Router links   : 1  (TREL peers on this network: 1)

Success. It should appear in HA → Settings → Devices & services → Thread within a few minutes.
```

You can also run steps on their own: `./install.sh build`, `flash`, `join`, or `status` (read-only
check; note that opening the serial port briefly restarts the board).

### 6. Check Home Assistant and install it

In **Settings → Devices & services → Thread**, your `BORDER_ROUTER_NAME` should now be listed under the
same network as your main border router.

Unplug the board and power it from any USB charger near the devices that need it. Nothing else is required: it
reconnects to Wi-Fi and rejoins Thread by itself after every power cut.

### 7. Move existing devices over

Battery devices keep their current connection until it breaks, so they may not switch to the new router
on their own. To move one now, **take its battery out for about 10 seconds and put it back.** It
reconnects through the closest router. For Matter devices you can check this in the Matter Server's Thread
map (Settings → Add-ons → Matter Server → Open Web UI).

Devices added through HA's **HomeKit Device** integration (HomeKit over Thread) don't appear in the
Matter Server at all. That's expected and doesn't mean they're offline.

## Troubleshooting

**"formed its own separate Thread partition"** (role `leader`, 0 router links): the board can't reach
Home Assistant's border router, either by radio or over the LAN. Check that it's on the same subnet/VLAN
as HA, that IPv6 and mDNS aren't blocked between them, and that the dataset came from the network HA marks as
*preferred*.

**"did not get an IP address"**: wrong Wi-Fi name or password, a 5 GHz-only network, or out of Wi-Fi
range. Fix the settings and run `./install.sh` again.

**No serial port appears**: try another USB-C cable (charge-only cables are common), or a different USB port.

**An old name still shows in HA after renaming**: mDNS caches expire within about an hour. Restarting
the OpenThread Border Router add-on clears it sooner.

**Watch the live log / use the Thread CLI**: from the `firmware` folder, with ESP-IDF activated
(`. ~/.espressif/tools/activate_idf_v5.5.5.sh`), run `idf.py -p <port> monitor`. Thread commands take an
`ot` prefix: `ot state`, `ot neighbor table`, `ot child table`. Exit with `Ctrl+]`.

## Undo

To wipe the board completely (firmware, Wi-Fi and Thread settings), with ESP-IDF activated:

```bash
cd firmware && idf.py -p <port> erase-flash
```

Your Home Assistant Thread network is never modified by this project; the board only joins it.

## What's different from Espressif's example

The firmware is Espressif's `examples/openthread/ot_br` from ESP-IDF v5.5.5, set up as a
single-chip, headless border router. If you want to build it yourself, the default config won't work, for these reasons:

- **Native radio** (`CONFIG_OPENTHREAD_RADIO_NATIVE`). The example defaults to a two-chip setup with a
  separate radio chip over UART.
- **TREL** (`CONFIG_OPENTHREAD_RADIO_TREL`). Without it, a board that can't hear your mesh by radio forms
  its own separate partition instead of joining Home Assistant's.
- **Rejoin on boot.** In ESP-IDF 5.5 the example connects Wi-Fi and starts the border router on boot, but
  leaves Thread off. `firmware/main/esp_ot_br.c` restarts Thread from the saved dataset, and never
  creates a new network if none is saved.
- **Console on the USB-C port** (`CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG`), so the Thread CLI accepts input.
- **Configurable names** for the Home Assistant label (MeshCoP instance name) and the `.local` hostname.

All of this is in `firmware/sdkconfig.defaults.esp32c6` and `firmware/main/esp_ot_br.c`.

## License

CC0 1.0, like the Espressif example it's based on.

---

*All Seeed Studio and Warp links on this page are affiliate links.*
