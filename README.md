# weewx-docker

[WeeWX](https://weewx.com) weather station software on Alpine Linux, with
[rtl_433](https://github.com/merbanan/rtl_433) for SDR-based stations.

```
ghcr.io/an0nfunc/weewx
```

Built for `linux/amd64`, `linux/arm64` and `linux/arm/v7`.

The image ships weewx and its dependencies, plus:

- pyserial and pyusb for serial and USB stations
- ephem for extended almanac data
- PyMySQL for MySQL or MariaDB databases
- paho-mqtt for MQTT extensions
- rtl_433 for the [SDR driver](https://github.com/matthewwall/weewx-sdr)
- rsync and ssh for the Rsync report

Everything specific to your station lives in one volume at `/data`, which is the
weewx station directory (`WEEWX_ROOT`): `weewx.conf`, extensions in `bin/user`,
skins, the database in `archive` and the generated reports in `public_html`.
Upgrading the image leaves all of it alone.

## Quick start

```yaml
# compose.yaml
services:
  weewx:
    image: ghcr.io/an0nfunc/weewx:5
    restart: unless-stopped
    environment:
      TZ: Europe/Berlin
    volumes:
      - ./data:/data
```

```sh
mkdir data   # must be writable by uid 1000, see "Running as another user"
docker compose up -d
```

On first start the container creates a station in `/data` that uses the
Simulator driver. Configure it for your hardware, then restart:

```sh
docker compose exec weewx weectl station reconfigure
docker compose restart weewx
```

Or edit `data/weewx.conf` directly. weewx uses local time for day and month
boundaries, so set `TZ` to the station's time zone (the default is UTC).

## Extensions

Install extensions with `weectl` as usual. They land in `/data` and survive image
upgrades.

```sh
docker compose exec weewx weectl extension install \
    https://github.com/matthewwall/weewx-sdr/archive/master.zip
docker compose restart weewx
```

If an extension needs a Python package the image does not ship, install it into
`/data/lib/python`. That directory comes after the image's own packages on the
Python path, so it can add packages but not replace shipped ones. This works for
packages that need no compiler.

```sh
docker compose exec weewx pip install --no-deps --target /data/lib/python some-package
```

Run `weectl` and `pip` as the container user, never with `-u 0`.

## Hardware

Pass the device into the container, and add a host group that owns only that
device so the container user may open it.

An RTL-SDR stick for rtl_433: USB device numbers change when the stick is
replugged, so the whole USB tree is passed in. That makes the group the only
thing between the container and every other USB device on the host, so give
the stick a group of its own with a udev rule on the host (IDs from `lsusb`):

```
# /etc/udev/rules.d/60-rtl-sdr.rules
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="0bda", ATTR{idProduct}=="2838", GROUP="rtlsdr", MODE="0660"
```

```sh
sudo groupadd -r rtlsdr
sudo udevadm control --reload && sudo udevadm trigger
getent group rtlsdr   # the gid for group_add
```

```yaml
    devices:
      - /dev/bus/usb:/dev/bus/usb
    group_add:
      - "970"   # gid of rtlsdr
```

Never add group 0, and never run the container as root while the USB tree is
passed in: root may open every USB device. The host's DVB-T kernel driver
(`dvb_usb_rtl28xxu`) must not claim the stick, so blacklist it on the host.

A serial or USB-serial station:

```yaml
    devices:
      - /dev/ttyUSB0:/dev/ttyUSB0
    group_add:
      - "20"    # stat -c %g /dev/ttyUSB0
```

## Logging

A station created by the container logs to the container output
(`docker compose logs weewx`). A `weewx.conf` brought over from another install
usually logs to syslog, which does not exist in the container. Add this section
to it:

```ini
[Logging]
    [[root]]
        handlers = console,
```

New stations also drop `weewx.engine.StdPrint` from `report_services`, since it
prints every packet. Remove it from an older config too if the log gets noisy.

## Reports

weewx writes the reports to `/data/public_html` but does not serve them. Point
a web server at that directory, or upload them with the FTP or Rsync report.

The Rsync report's ssh key and `known_hosts` must live in `/data` to survive a
new container. Point the report at them in `weewx.conf`:

```ini
        ssh_options = -i /data/.ssh/id_ed25519 -o UserKnownHostsFile=/data/.ssh/known_hosts
```

## Running as another user

The container runs as uid and gid 1000. To match the owner of an existing data
directory, set the user instead:

```yaml
    user: "967:967"
```

A uid without an entry in the image's `/etc/passwd` has two limits. ssh refuses
to run, and with it the Rsync report. `weectl station upgrade` must skip the
`util` files (`--what config examples skins`).

## Moving an existing station in

1. Stop the old weewx.
2. Copy into the data directory: `weewx.conf`, the extensions (`bin/user`), the
   skins and the SQLite database (into `archive/`). Everything must be owned by
   the container user, and `weewx.conf` should be mode 600.
3. In `weewx.conf`, remove `WEEWX_ROOT` (it then defaults to the directory of
   the config file) and make `SKIN_ROOT`, `HTML_ROOT` and `SQLITE_ROOT` relative:
   `skins`, `public_html`, `archive`.
4. Add the `[Logging]` section above.
5. Start the container.

The image runs Python 3.14. Extensions written before Python 3.12 may import
`distutils`, which no longer exists, and stop weewxd from starting. Reinstall
the current release of such an extension.

## Upgrading

Pull the new image and recreate the container. The stock skins in `/data/skins`
are copies, so update them and the config format with:

```sh
docker compose exec weewx weectl station upgrade --what config skins
```

## Tags

| Tag | Meaning |
|-----|---------|
| `5.6.0`, `5.6`, `5`, `latest` | weewx version; rebuilt weekly with Alpine updates |
| `sha-<commit>` | the build from one commit of this repository |

## License

The files in this repository are MIT licensed. The image contains weewx
(GPL-3.0-only) and rtl_433 (GPL-2.0-or-later), under their own licenses.
