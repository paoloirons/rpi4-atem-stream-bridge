#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="/opt/rpi-srt-atem"
AP_PROFILE="rpi-atem-ap"
AP_IFACE="wlan0"
AP_ADDRESS="${AP_ADDRESS:-192.168.50.1}"
AP_CHANNEL="${AP_CHANNEL:-6}"
AP_SSID="${AP_SSID:-Pi-ATEM}"
AP_PASSWORD="${AP_PASSWORD:-}"
BOOT_FILE=""
BOOT_CHANGED=0

log() { printf '\n[pi-atem] %s\n' "$*"; }
fail() { printf '\n[pi-atem] ERROR: %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || fail "Run this script with sudo: sudo ./install.sh"
[[ -f "${PROJECT_SOURCE}/compose.yaml" ]] || fail "Run this script from the project directory."

source /etc/os-release
[[ "${ID:-}" == "raspbian" || -f /etc/rpi-issue ]] || fail "This installer supports Raspberry Pi OS only."
[[ "${VERSION_CODENAME:-}" == "bookworm" ]] || fail "Use Raspberry Pi OS Bookworm 64-bit Desktop for this first release."
[[ "$(dpkg --print-architecture)" == "arm64" ]] || fail "A 64-bit Raspberry Pi OS installation is required."
command -v labwc >/dev/null 2>&1 || fail "The Raspberry Pi OS Desktop with labwc is required; Raspberry Pi OS Lite is not supported."
MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
[[ "${MODEL}" == *"Raspberry Pi 4"* ]] || fail "This profile is currently configured for Raspberry Pi 4."

if [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]]; then
  printf 'This will reconfigure %s as a Wi-Fi access point and may disconnect this SSH session.\n' "${AP_IFACE}"
  read -r -p 'Type CONTINUE to proceed: ' confirmation
  [[ "${confirmation}" == "CONTINUE" ]] || fail "Cancelled before changing network settings."
fi

if [[ -z "${AP_PASSWORD}" ]]; then
  if [[ ! -t 0 ]]; then
    fail "Set AP_PASSWORD in the environment when running non-interactively."
  fi
  read -r -s -p "Choose a WPA2 password for ${AP_SSID} (8–63 characters): " AP_PASSWORD
  printf '\n'
fi
[[ "${#AP_PASSWORD}" -ge 8 && "${#AP_PASSWORD}" -le 63 ]] || fail "The access point password must contain 8–63 characters."
[[ "${#AP_SSID}" -ge 1 && "${#AP_SSID}" -le 32 ]] || fail "The Wi-Fi name must contain 1–32 characters."
[[ "${AP_CHANNEL}" == "1" || "${AP_CHANNEL}" == "6" || "${AP_CHANNEL}" == "11" ]] || fail "Choose 2.4 GHz channel 1, 6, or 11."
python3 - "${AP_ADDRESS}" "${AP_IFACE}" <<'PY' || fail "AP_ADDRESS must be a free private IPv4 subnet address ending in .1."
import ipaddress, json, subprocess, sys
try:
    ip = ipaddress.ip_address(sys.argv[1])
    private = (ipaddress.ip_network("10.0.0.0/8"), ipaddress.ip_network("172.16.0.0/12"), ipaddress.ip_network("192.168.0.0/16"))
    assert isinstance(ip, ipaddress.IPv4Address) and any(ip in network for network in private) and ip.packed[-1] == 1
    subnet = ipaddress.ip_network(f"{ip}/24", strict=False)
    routes = json.loads(subprocess.check_output(["ip", "-j", "route", "show"], text=True))
    for route in routes:
        destination = route.get("dst", "default")
        if route.get("dev") == sys.argv[2] or destination == "default":
            continue
        try:
            connected = ipaddress.ip_network(destination, strict=False)
        except ValueError:
            continue
        assert not subnet.overlaps(connected), f"{subnet} overlaps {destination} on {route.get('dev')}"
except Exception as error:
    print(error, file=sys.stderr)
    raise SystemExit(1)
PY

log "Installing host prerequisites and Docker Engine / Compose from Docker's Debian repository."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg iw network-manager python3 rsync wlr-randr x11-xserver-utils
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
DOCKER_ARCH="$(dpkg --print-architecture)"
printf 'Types: deb\nURIs: https://download.docker.com/linux/debian\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.gpg\n' \
  "${VERSION_CODENAME}" "${DOCKER_ARCH}" >/etc/apt/sources.list.d/docker.sources
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker NetworkManager

log "Configuring the Raspberry Pi Wi-Fi access point."
if command -v raspi-config >/dev/null 2>&1; then
  raspi-config nonint do_wifi_country IT || true
  raspi-config nonint do_boot_behaviour B4 || true
fi
iw reg set IT || true
nmcli radio wifi on
if ! nmcli -g WIFI-PROPERTIES.AP device show "${AP_IFACE}" 2>/dev/null | grep -Fxq yes; then
  fail "The Wi-Fi adapter ${AP_IFACE} does not report access point mode support."
fi
if ! nmcli -t -f NAME connection show | grep -Fxq "${AP_PROFILE}"; then
  nmcli connection add type wifi ifname "${AP_IFACE}" con-name "${AP_PROFILE}" ssid "${AP_SSID}"
fi
nmcli connection modify "${AP_PROFILE}" \
  connection.autoconnect yes \
  connection.autoconnect-priority 100 \
  802-11-wireless.ssid "${AP_SSID}" \
  802-11-wireless.mode ap \
  802-11-wireless.band bg \
  802-11-wireless.channel "${AP_CHANNEL}" \
  wifi-sec.key-mgmt wpa-psk \
  wifi-sec.psk "${AP_PASSWORD}" \
  ipv4.method shared \
  ipv4.addresses "${AP_ADDRESS}/24" \
  ipv6.method disabled
nmcli connection up "${AP_PROFILE}" ifname "${AP_IFACE}"

log "Preparing persistent KMS video modes for both HDMI connectors."
if [[ -f /boot/firmware/cmdline.txt ]]; then
  BOOT_FILE=/boot/firmware/cmdline.txt
elif [[ -f /boot/cmdline.txt ]]; then
  BOOT_FILE=/boot/cmdline.txt
else
  fail "Could not find the Raspberry Pi kernel command line file."
fi
if [[ ! -e "${BOOT_FILE}.pi-atem.bak" ]]; then
  cp -a "${BOOT_FILE}" "${BOOT_FILE}.pi-atem.bak"
fi
python3 - "${BOOT_FILE}" <<'PY'
from pathlib import Path
import re, sys
path = Path(sys.argv[1])
line = path.read_text().strip()
tokens = [token for token in line.split() if not re.fullmatch(r"video=HDMI-A-[12]:.*", token)]
tokens += ["video=HDMI-A-1:1920x1080@50D", "video=HDMI-A-2:1920x1080@50D"]
path.write_text(" ".join(tokens) + "\n")
PY
ACTIVE_CMDLINE="$(cat /proc/cmdline)"
if [[ "${ACTIVE_CMDLINE}" != *"video=HDMI-A-1:1920x1080@50D"* || "${ACTIVE_CMDLINE}" != *"video=HDMI-A-2:1920x1080@50D"* ]]; then
  BOOT_CHANGED=1
fi

log "Installing the project and host dashboard."
install -d -m 0755 "${INSTALL_ROOT}"
rsync -a --delete --exclude .git --exclude .env --exclude target "${PROJECT_SOURCE}/" "${INSTALL_ROOT}/"
DESKTOP_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
[[ -n "${DESKTOP_USER}" ]] || DESKTOP_USER="pi"
DESKTOP_HOME="$(getent passwd "${DESKTOP_USER}" | cut -d: -f6)"
[[ -n "${DESKTOP_HOME}" ]] || fail "Could not find the home directory for desktop user ${DESKTOP_USER}."
if ! id -nG "${DESKTOP_USER}" | tr ' ' '\n' | grep -Fxq docker; then
  usermod -aG docker "${DESKTOP_USER}"
fi
if [[ ! -f "${INSTALL_ROOT}/.env" ]]; then
  cat >"${INSTALL_ROOT}/.env" <<EOF
AP_BIND_IP=${AP_ADDRESS}
DISPLAY=:0
HDMI0_WINDOW_POS=0,0
HDMI1_WINDOW_POS=1920,0
EOF
  chmod 0600 "${INSTALL_ROOT}/.env"
else
  if grep -q '^AP_BIND_IP=' "${INSTALL_ROOT}/.env"; then
    sed -i "s/^AP_BIND_IP=.*/AP_BIND_IP=${AP_ADDRESS}/" "${INSTALL_ROOT}/.env"
  else
    printf '\nAP_BIND_IP=%s\n' "${AP_ADDRESS}" >>"${INSTALL_ROOT}/.env"
  fi
fi
install -m 0644 "${INSTALL_ROOT}/rpi-atem-host.service" /etc/systemd/system/rpi-atem-host.service
install -m 0644 "${INSTALL_ROOT}/rpi-atem-compose.service" /etc/systemd/system/rpi-atem-compose.service
install -m 0755 "${INSTALL_ROOT}/configure-displays.sh" /usr/local/bin/pi-atem-configure-displays
LABWC_DIR="${DESKTOP_HOME}/.config/labwc"
AUTOSTART="${LABWC_DIR}/autostart"
install -d -m 0755 "${LABWC_DIR}"
touch "${AUTOSTART}"
if ! grep -Fq 'pi-atem-configure-displays' "${AUTOSTART}"; then
  cat >>"${AUTOSTART}" <<'EOF'

# Keep both Raspberry Pi 4 HDMI outputs in an extended 1080p50 layout.
/usr/local/bin/pi-atem-configure-displays >/tmp/pi-atem-displays.log 2>&1 &
EOF
fi
chown -R "${DESKTOP_USER}:${DESKTOP_USER}" "${DESKTOP_HOME}/.config/labwc"
systemctl daemon-reload
systemctl enable --now rpi-atem-host.service
systemctl enable rpi-atem-compose.service

log "Building and starting the video receiver and both HTTPS control pages."
docker compose --project-directory "${INSTALL_ROOT}" up -d --build
systemctl start rpi-atem-compose.service

printf '\nSetup complete.\n'
printf 'Wi-Fi: %s  Address: %s  Channel: %s\n' "${AP_SSID}" "${AP_ADDRESS}" "${AP_CHANNEL}"
printf 'Host dashboard: https://%s:8444\n' "${AP_ADDRESS}"
printf 'Video panel:     https://%s:8443\n' "${AP_ADDRESS}"
printf 'Connect a phone to the access point and publish SRT to UDP port 8890.\n'
printf 'Log out and back in for Docker group membership to apply to %s.\n' "${DESKTOP_USER}"
if [[ "${BOOT_CHANGED}" -eq 1 ]]; then
  printf 'A reboot is required to apply both always-on 1080p50 HDMI modes.\n'
else
  printf 'Both always-on 1080p50 HDMI modes are already configured.\n'
fi
