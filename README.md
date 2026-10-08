# Raspberry Pi 4 ATEM Stream Bridge

An installable Raspberry Pi 4 appliance for receiving two mobile video feeds and routing them independently to the Pi's two micro-HDMI outputs. The project uses SRT for mobile contribution, MediaMTX for ingest, a Rust/Axum control panel, FFplay for display, Caddy for HTTPS, and a small loopback-only host agent for access point settings and system monitoring.

## What the installer configures

Run `install.sh` once on a fresh Raspberry Pi OS Bookworm 64-bit Desktop installation. It:

- Installs or updates Docker Engine and the Docker Compose plugin from Docker's Debian package repository.
- Creates a WPA2-protected 2.4 GHz Wi-Fi access point on `wlan0`, with DHCP and NAT, using the password entered during setup.
- Sets both KMS HDMI connectors to an always-enabled 1920×1080 at 50 Hz mode, including when an ATEM or HDMI cable is attached after boot.
- Configures the Bookworm `labwc` desktop with the two displays extended side by side.
- Grants the local root-owned video container access to X11 from the desktop autostart file.
- Enables desktop auto-login so the display session is available again after a reboot.
- Installs a host dashboard on HTTPS port `8444` and the video routing panel on HTTPS port `8443`.
- Builds the containers, starts them, and installs systemd units so the host agent and containers return after reboot.

The installer keeps an unmodified backup of the kernel command line at `cmdline.txt.pi-atem.bak`. It does not format storage or replace Raspberry Pi OS. A reboot is required the first time to apply the kernel HDMI modes.

## Install

Clone this repository on the Pi, connect it to Ethernet for package downloads, and run:

```sh
cd rpi4-atem-stream-bridge
sudo ./install.sh
```

Choose a strong WPA2 password when prompted. The defaults are SSID `Pi-ATEM`, access point address `192.168.50.1`, and Wi-Fi channel 6. You can override them before running the script:

```sh
sudo AP_SSID="Studio-ATEM" AP_ADDRESS="192.168.50.1" AP_CHANNEL=6 ./install.sh
```

For a non-interactive install, also provide `AP_PASSWORD` in the environment. Avoid saving that password in a shell history or committing it to the repository. The installer adds the invoking desktop user to the `docker` group; log out and back in before using Docker without `sudo`.

The script repurposes the Pi's built-in Wi-Fi radio as an access point. If you run it over SSH through `wlan0`, it asks for an explicit `CONTINUE` because that session can disconnect. Use Ethernet or a local keyboard and display for the most reliable first setup.

After setup, reboot the Pi. It boots into the graphical desktop automatically. Connect the ATEM to the Pi's two micro-HDMI outputs. The desktop must remain running because FFplay opens fullscreen windows on its display session.

## Control pages

Connect a phone to the Pi access point. The first visit to either HTTPS page uses a locally generated certificate, so the browser will show a certificate warning unless Caddy's local root CA is installed on the phone.

| Page | Address | Purpose |
| --- | --- | --- |
| Host and Wi-Fi dashboard | `https://192.168.50.1:8444` | CPU load, memory, temperature, storage, uptime, network interfaces, connected Wi-Fi clients, and AP settings. |
| Video routing panel | `https://192.168.50.1:8443` | Assign `cam1` or `cam2` to HDMI 0 and HDMI 1 independently, or show a black standby frame. |

The dashboard can change the SSID, Wi-Fi password, 2.4 GHz channel, and AP address. Each change has a 90-second rollback: reconnect to the new network, open the dashboard at its new address, and confirm. If you do not confirm, the previous settings are restored automatically. The dashboard is bound to the access point; protect it with a strong password and only connect trusted devices.

The AP address must be a private IPv4 address ending in `.1`; the AP uses a `/24` subnet and NetworkManager's shared mode for DHCP/NAT. The AP radio is 2.4 GHz, and the control page offers channels 1, 6, and 11.

## Send video from a phone

Install Larix Broadcaster on Android or iOS. Create an SRT Caller destination for each phone, using one of these stream URLs:

```text
srt://192.168.50.1:8890?streamid=publish:cam1&latency=250000
srt://192.168.50.1:8890?streamid=publish:cam2&latency=250000
```

Use H.264, 720p at 25 or 30 fps, and a moderate bitrate for the first test. Start each Larix feed, open the video routing panel, and assign each camera to an HDMI output. The Pi can show the same source on both outputs if needed. The black/standby option keeps a full-frame black video signal on the selected HDMI output.

## Display and performance notes

- HDMI is configured for 1080p50 to match a common European ATEM production format. Set the ATEM video standard to 1080p50. To change the output mode, edit the two `video=HDMI-A-*` arguments in the boot command line and the display mode in `configure-displays.sh` together.
- Raspberry Pi OS Bookworm uses Wayland with `labwc`. The installer configures the outputs and grants local X11 access to the controller container at desktop startup. If the desktop session or display manager is changed later, check the HDMI layout and X11 compatibility before using the bridge.
- The host agent runs as root so NetworkManager can change the AP. It listens only on `127.0.0.1`; Caddy exposes its dashboard only on the AP address.
- The AP provides DHCP and NAT, but the Pi needs Ethernet or another uplink for phones to reach the internet.
- FFplay routes audio to the host's default audio device. Per-HDMI embedded audio routing may need extra configuration; this first release focuses on video.
- This is an experimental first release. Test one 720p stream first. Two simultaneous 1080p decodes may exceed the Pi 4's practical capacity.

## Useful commands

```sh
cd /opt/rpi-srt-atem
sudo docker compose ps
sudo docker compose logs -f
sudo systemctl status rpi-atem-host rpi-atem-compose
sudo journalctl -u rpi-atem-host -f
```

To stop the video services while leaving the access point and host dashboard available:

```sh
sudo docker compose down
```

## Technical references

- [Raspberry Pi OS display configuration](https://www.raspberrypi.com/documentation/computers/configuration.html)
- [Raspberry Pi KMS HDMI troubleshooting](https://pip.raspberrypi.com/categories/685-app-notes-guides-whitepapers/documents/RP-004341-WP/Troubleshooting-KMS-HDMI-output.pdf)
- [Docker Engine installation on Debian](https://docs.docker.com/engine/install/debian/)
- [NetworkManager IPv4 shared mode](https://www.networkmanager.dev/docs/api/latest/settings-ipv4.html)
- [MediaMTX SRT clients](https://github.com/bluenviron/mediamtx/blob/main/docs/4-read/02-srt.md)
