#!/usr/bin/env python3
"""Loopback-only host agent for the Raspberry Pi control dashboard."""

from __future__ import annotations

import ipaddress
import json
import os
import re
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(os.environ.get("RPI_ATEM_ROOT", "/opt/rpi-srt-atem"))
PAGE = ROOT / "host-dashboard.html"
PROFILE = os.environ.get("AP_PROFILE", "rpi-atem-ap")
WIFI_IFACE = os.environ.get("AP_IFACE", "wlan0")
ADDRESS = ("127.0.0.1", 18081)
ALLOWED_CHANNELS = {1, 6, 11}
PRIVATE_V4_NETWORKS = tuple(map(ipaddress.ip_network, ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")))
state_lock = threading.Lock()
pending_change: dict | None = None
rollback_timer: threading.Timer | None = None
pending_deadline: float | None = None
previous_cpu: tuple[int, int] | None = None


def run(args: list[str], timeout: int = 8, check: bool = True) -> str:
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        message = result.stderr.strip() or result.stdout.strip() or "Command failed"
        raise RuntimeError(message)
    return result.stdout.strip()


def nm_value(property_name: str, *, secrets: bool = False) -> str:
    args = ["nmcli"]
    if secrets:
        args.append("--show-secrets")
    args += ["-g", property_name, "connection", "show", PROFILE]
    return run(args)


def current_ap() -> dict:
    result = {}
    for key, prop in {
        "ssid": "802-11-wireless.ssid",
        "channel": "802-11-wireless.channel",
        "address": "ipv4.addresses",
    }.items():
        try:
            result[key] = nm_value(prop)
        except Exception:
            result[key] = ""
    result["address"] = result["address"].split("/")[0]
    return result


def interfaces() -> list[dict]:
    try:
        data = json.loads(run(["ip", "-j", "address", "show"]))
    except Exception:
        return []
    found = []
    for item in data:
        addresses = [entry["local"] + "/" + str(entry["prefixlen"])
                     for entry in item.get("addr_info", []) if entry.get("family") == "inet"]
        found.append({"name": item.get("ifname", "?"), "state": item.get("operstate", "unknown"),
                      "addresses": addresses})
    return found


def default_routes() -> list[dict]:
    try:
        routes = json.loads(run(["ip", "-j", "route", "show", "default"]))
    except Exception:
        return []
    return [{"interface": route.get("dev", "?"), "gateway": route.get("gateway", "direct"),
             "metric": route.get("metric", 0)} for route in routes]


def check_address_overlap(address: ipaddress.IPv4Address) -> None:
    subnet = ipaddress.ip_network(f"{address}/24", strict=False)
    try:
        routes = json.loads(run(["ip", "-j", "route", "show"]))
    except Exception:
        return
    for route in routes:
        destination = route.get("dst", "default")
        if route.get("dev") == WIFI_IFACE or destination == "default":
            continue
        try:
            connected = ipaddress.ip_network(destination, strict=False)
        except ValueError:
            continue
        if subnet.overlaps(connected):
            raise ValueError(f"The {subnet} access point subnet overlaps {destination} on {route.get('dev', 'another interface')}.")


def station_count() -> int:
    try:
        output = run(["iw", "dev", WIFI_IFACE, "station", "dump"])
        return sum(1 for line in output.splitlines() if line.startswith("Station "))
    except Exception:
        return 0


def cpu_load() -> float | None:
    global previous_cpu
    try:
        fields = Path("/proc/stat").read_text().splitlines()[0].split()[1:]
        values = [int(value) for value in fields]
        idle = values[3] + (values[4] if len(values) > 4 else 0)
        total = sum(values)
        old = previous_cpu
        previous_cpu = (idle, total)
        if old is None or total == old[1]:
            return None
        return round(100 * (1 - (idle - old[0]) / (total - old[1])), 1)
    except Exception:
        return None


def host_status() -> dict:
    meminfo = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        match = re.match(r"(\w+):\s+(\d+)", line)
        if match:
            meminfo[match.group(1)] = int(match.group(2))
    total = meminfo.get("MemTotal", 0)
    available = meminfo.get("MemAvailable", 0)
    temp = None
    try:
        temp = round(int(Path("/sys/class/thermal/thermal_zone0/temp").read_text()) / 1000, 1)
    except Exception:
        pass
    try:
        uptime = int(float(Path("/proc/uptime").read_text().split()[0]))
    except Exception:
        uptime = 0
    try:
        load = [round(float(value), 2) for value in Path("/proc/loadavg").read_text().split()[:3]]
    except Exception:
        load = []
    disk = shutil.disk_usage("/")
    try:
        active = run(["nmcli", "-g", "GENERAL.CONNECTION", "device", "show", WIFI_IFACE])
    except Exception:
        active = "unavailable"
    try:
        regulatory = run(["iw", "reg", "get"])
        match = re.search(r"^country\s+([A-Z0-9]{2}):", regulatory, re.MULTILINE)
        reg = match.group(1) if match else "unset"
    except Exception:
        reg = "unavailable"
    return {
        "cpu_percent": cpu_load(),
        "memory_total_mb": round(total / 1024),
        "memory_used_mb": round((total - available) / 1024),
        "temperature_c": temp,
        "load": load,
        "uptime_seconds": uptime,
        "disk_total_gb": round(disk.total / 1_000_000_000, 1),
        "disk_free_gb": round(disk.free / 1_000_000_000, 1),
        "wifi_interface": WIFI_IFACE,
        "wifi_connection": active,
        "wifi_clients": station_count(),
        "regulatory_domain": reg,
        "interfaces": interfaces(),
        "default_routes": default_routes(),
        "ap": current_ap(),
        "pending_change": pending_change is not None,
        "pending_seconds": max(0, int(pending_deadline - time.monotonic())) if pending_deadline else 0,
    }


def write_bind_ip(address: str) -> None:
    path = ROOT / ".env"
    lines = path.read_text().splitlines() if path.exists() else []
    updated = False
    for index, line in enumerate(lines):
        if line.startswith("AP_BIND_IP="):
            lines[index] = f"AP_BIND_IP={address}"
            updated = True
            break
    if not updated:
        lines.append(f"AP_BIND_IP={address}")
    temporary = ROOT / ".env.new"
    temporary.write_text("\n".join(lines) + "\n")
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def restart_bound_services() -> None:
    run(["docker", "compose", "--project-directory", str(ROOT), "up", "-d", "--no-build", "panel", "mediamtx"], timeout=45)


def set_profile(settings: dict) -> None:
    run([
        "nmcli", "connection", "modify", PROFILE,
        "802-11-wireless.ssid", settings["ssid"],
        "802-11-wireless.channel", str(settings["channel"]),
        "wifi-sec.key-mgmt", "wpa-psk",
        "wifi-sec.psk", settings["password"],
        "ipv4.method", "shared",
        "ipv4.addresses", settings["address"] + "/24",
        "ipv6.method", "disabled",
    ])
    run(["nmcli", "connection", "up", PROFILE], timeout=20)


def rollback() -> None:
    global pending_change, rollback_timer, pending_deadline
    with state_lock:
        change = pending_change
        if change is None:
            return
        try:
            set_profile(change["old"])
            write_bind_ip(change["old"]["address"])
            restart_bound_services()
        finally:
            pending_change = None
            rollback_timer = None
            pending_deadline = None


def validate_settings(payload: dict) -> dict:
    ssid = str(payload.get("ssid", "")).strip()
    password = str(payload.get("password", ""))
    try:
        channel = int(payload.get("channel", 6))
    except (TypeError, ValueError):
        raise ValueError("Choose Wi-Fi channel 1, 6, or 11.")
    try:
        address = ipaddress.ip_address(str(payload.get("address", "")))
    except ValueError:
        raise ValueError("Enter a valid private IPv4 address ending in .1.")
    if not isinstance(address, ipaddress.IPv4Address) or not any(address in network for network in PRIVATE_V4_NETWORKS) or address.packed[-1] != 1:
        raise ValueError("The access point address must be a private IPv4 ending in .1.")
    check_address_overlap(address)
    if not ssid or len(ssid.encode("utf-8")) > 32 or any(ord(char) < 32 for char in ssid):
        raise ValueError("The Wi-Fi name must be 1–32 UTF-8 bytes without control characters.")
    if password and not 8 <= len(password.encode("utf-8")) <= 63:
        raise ValueError("The Wi-Fi password must be 8–63 UTF-8 bytes.")
    if channel not in ALLOWED_CHANNELS:
        raise ValueError("Choose Wi-Fi channel 1, 6, or 11.")
    return {"ssid": ssid, "password": password, "channel": channel, "address": str(address)}


class Handler(BaseHTTPRequestHandler):
    server_version = "PiAtemHost/1.0"

    def log_message(self, format_string: str, *args) -> None:
        print("host-agent: " + format_string % args)

    def send_json(self, data: dict, status: int = 200) -> None:
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/":
            try:
                body = PAGE.read_bytes()
            except OSError:
                self.send_error(503, "Dashboard file is missing")
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/api/status":
            try:
                self.send_json(host_status())
            except Exception as error:
                self.send_json({"error": str(error)}, 500)
        else:
            self.send_error(404)

    def do_POST(self) -> None:
        global pending_change, rollback_timer, pending_deadline
        if self.path == "/api/ap/confirm":
            with state_lock:
                if pending_change is None:
                    self.send_json({"error": "There is no pending access point change."}, 409)
                    return
                if rollback_timer:
                    rollback_timer.cancel()
                pending_change = None
                rollback_timer = None
                pending_deadline = None
            self.send_json({"ok": True})
            return
        if self.path != "/api/ap/apply":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 4096:
                raise ValueError("Invalid request size.")
            payload = json.loads(self.rfile.read(length))
            if not isinstance(payload, dict):
                raise ValueError("Expected a JSON object with access point settings.")
            settings = validate_settings(payload)
            with state_lock:
                if pending_change is not None:
                    raise ValueError("Confirm or wait for the current network change to roll back.")
                old = current_ap()
                old["password"] = nm_value("wifi-sec.psk", secrets=True)
                old["channel"] = int(old["channel"] or 6)
                if not settings["password"]:
                    settings["password"] = old["password"]
                try:
                    set_profile(settings)
                    write_bind_ip(settings["address"])
                    restart_bound_services()
                except Exception:
                    set_profile(old)
                    write_bind_ip(old["address"])
                    restart_bound_services()
                    raise
                pending_change = {"old": old}
                pending_deadline = time.monotonic() + 90
                rollback_timer = threading.Timer(90, rollback)
                rollback_timer.daemon = True
                rollback_timer.start()
            self.send_json({"ok": True, "confirm_within_seconds": 90, "address": settings["address"]})
        except (ValueError, json.JSONDecodeError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
            self.send_json({"error": str(error)}, 400)


if __name__ == "__main__":
    if os.geteuid() != 0:
        raise SystemExit("Run this agent as root through its systemd service.")
    print(f"Starting AP dashboard host agent at http://{ADDRESS[0]}:{ADDRESS[1]}")
    ThreadingHTTPServer(ADDRESS, Handler).serve_forever()
