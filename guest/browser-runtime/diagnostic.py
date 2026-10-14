#!/usr/bin/python3
"""Build-only diagnostic: rendered Firefox, process sandbox, settings and PNG.

This is never enabled as a production service and does not inspect pages,
credentials, or a real user profile. It runs against the bundled local check page.
"""
import base64
import json
import os
from pathlib import Path
import subprocess
import time
import re
from urllib.parse import unquote


def command(arguments):
    result = subprocess.run(arguments, capture_output=True, text=True, check=True)
    return result.stdout.strip()


# Cover the late failure window from the earlier 88/110-second GUI boots.
short_check = "browser.verify_short=1" in Path("/proc/cmdline").read_text().split()
time.sleep(8 if short_check else 150)
environment = dict(os.environ, DISPLAY=":0", XAUTHORITY="/root/.Xauthority")
marker = Path("/home/browser/.browser-build-persistence")
preexisting_marker = marker.exists() and marker.read_text() == "public-build-fixture/v1\n"
if not marker.exists():
    marker.write_text("public-build-fixture/v1\n")
    os.chown(marker, 59998, 59998)
    marker.chmod(0o600)
png = Path("/tmp/browser-build.png")
subprocess.run(["/usr/bin/scrot", str(png)], env=environment, check=True)
windows = command(["/usr/bin/xprop", "-display", ":0", "-root", "_NET_CLIENT_LIST"])
window_evidence = []
for window in windows.split("#", 1)[1].replace(",", " ").split():
    window_evidence.append(command(["/usr/bin/xprop", "-display", ":0", "-id", window, "WM_CLASS", "_NET_WM_NAME"]))
web_observations = []
for window in window_evidence:
    match = re.search(r"PLATFORM=([^ ]+) CPU=([0-9]+) GPU=([^ ]+)", window)
    if match:
        offset = re.search(r"OFFSET=(-?[0-9]+)", window)
        if not offset:
            raise RuntimeError("web_utc_offset_observation_missing")
        web_observations.append({"platform": unquote(match.group(1)), "hardware_concurrency": int(match.group(2)),
                                 "webgl_renderer": unquote(match.group(3).split('"', 1)[0]), "utc_offset_minutes": int(offset.group(1))})
processes = []
for entry in Path("/proc").iterdir():
    if not entry.name.isdigit():
        continue
    try:
        name = (entry / "comm").read_text().strip()
        command_line = (entry / "cmdline").read_bytes()
        if b"/opt/firefox/firefox" not in command_line:
            continue
        status = (entry / "status").read_text()
        security = {line.split(":", 1)[0]: line.split(":", 1)[1].strip()
                    for line in status.splitlines() if line.startswith(("Uid:", "Seccomp:", "NoNewPrivs:"))}
        processes.append({"pid": int(entry.name), "name": name, "security": security,
                          "user_namespace": str((entry / "ns/user").readlink()),
                          "content_process": b"-contentproc" in command_line})
    except FileNotFoundError:
        # A short-lived subprocess can exit while /proc is enumerated.
        continue

def browser_can_write(path):
    result = subprocess.run(["/usr/sbin/runuser", "-u", "browser", "--", "/usr/bin/test", "-w", str(path)])
    if result.returncode not in (0, 1):
        raise RuntimeError("browser_write_permission_check_failed")
    return result.returncode == 0

evidence = {
    "schema": "browser-guest-build-check/v1",
    "gui_observation_seconds": 8 if short_check else 150,
    "firefox_version": command(["/opt/firefox/firefox", "--version"]),
    "network_interfaces": sorted(path.name for path in Path("/sys/class/net").iterdir()),
    "timezone": Path("/etc/timezone").read_text().strip(),
    "utc_epoch_seconds": int(time.time()),
    "build_profile_marker_preexisting": preexisting_marker,
    "locale": command(["/usr/sbin/runuser", "-u", "browser", "--", "/usr/bin/locale"]),
    "display": command(["/usr/bin/xrandr", "-display", ":0"]),
    "windows": window_evidence,
    "web_observations": web_observations,
    "processes": processes,
    "proxy_listener": command(["/usr/bin/ss", "-lntp", "sport = :7890"]),
    "profile_writable": command(["/usr/sbin/runuser", "-u", "browser", "--", "/usr/bin/test", "-w", "/home/browser/.mozilla/browser"]),
    "system_root_owned": all(path.stat().st_uid == 0 and path.stat().st_mode & 0o022 == 0
                             for path in (Path("/opt/firefox/browser.cfg"), Path("/opt/firefox/distribution/policies.json"), Path("/opt/browser/proxy.py"))),
    "sandbox_not_disabled": not any(key.startswith("MOZ_DISABLE") for key in os.environ),
    "system_paths_browser_writable": {str(path): browser_can_write(path) for path in (
        Path("/opt/browser"), Path("/opt/firefox"), Path("/opt/firefox/browser.cfg"),
        Path("/opt/firefox/distribution/policies.json"), Path("/etc/systemd/system/browser-session.service"))},
    "policy_json": json.loads(Path("/opt/firefox/distribution/policies.json").read_text()),
    "locked_config": Path("/opt/firefox/browser.cfg").read_text(),
}
print("BROWSER_DIAGNOSTIC_BEGIN", flush=True)
print(json.dumps(evidence, sort_keys=True), flush=True)
print("BROWSER_DIAGNOSTIC_END", flush=True)
print("BROWSER_SCREENSHOT_BEGIN", flush=True)
print(base64.b64encode(png.read_bytes()).decode("ascii"), flush=True)
print("BROWSER_SCREENSHOT_END", flush=True)
png.unlink()
