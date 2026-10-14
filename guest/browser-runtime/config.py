#!/usr/bin/python3
"""Read bounded typed session settings from a read-only ISO, never execute content."""
import json
from pathlib import Path
import stat
import subprocess
import sys


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_config_key")
        result[key] = value
    return result


def main():
    mount = Path("/run/browser-config")
    mount.mkdir(mode=0o700, parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/mount", "-t", "iso9660", "-o", "ro,nosuid,nodev,noexec", "/dev/vdc", str(mount)], check=True)
    try:
        source = mount / "browser-config.json"
        info = source.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size > 256:
            raise ValueError("session_config_file_invalid")
        config = json.loads(source.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
        if type(config) is not dict or set(config) != {"schema", "resist_fingerprinting", "boot_epoch_seconds"}:
            raise ValueError("session_config_fields_invalid")
        if config["schema"] != "browser-session-config/v1" or type(config["resist_fingerprinting"]) is not bool:
            raise ValueError("session_config_value_invalid")
        epoch = config["boot_epoch_seconds"]
        if type(epoch) is not int or not 1735689600 <= epoch <= 4102444800:
            raise ValueError("session_clock_value_invalid")
        subprocess.run(["/usr/bin/date", "-u", "-s", "@" + str(epoch)], check=True, capture_output=True)
        path = Path("/opt/firefox/browser.cfg")
        text = path.read_text()
        keys = {"privacy.resistFingerprinting": config["resist_fingerprinting"],
                "privacy.spoof_english": 2 if config["resist_fingerprinting"] else 0,
                "intl.accept_languages": "en-US,en" if config["resist_fingerprinting"] else "ja,en-US,en"}
        for key, value in keys.items():
            lines = text.splitlines(keepends=True)
            matches = [index for index, line in enumerate(lines) if line.startswith("lockPref(" + json.dumps(key) + ", ")]
            if len(matches) != 1:
                raise ValueError("local_config_contract_missing")
            lines[matches[0]] = "lockPref(" + json.dumps(key) + ", " + json.dumps(value) + ");\n"
            text = "".join(lines)
        path.write_text(text)
        with open("/dev/hvc0", "w") as serial:
            serial.write("BROWSER_CONFIG_READY\n")
    finally:
        subprocess.run(["/usr/bin/umount", str(mount)], check=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        with open("/dev/hvc0", "w") as serial:
            serial.write("BROWSER_CONFIG_FAILED\n")
        print(json.dumps({"kind": "browser_config_failed", "error": str(error)}), file=sys.stderr)
        raise SystemExit(1)
