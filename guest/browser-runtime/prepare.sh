#!/bin/bash
set -euo pipefail
exec > /dev/hvc0 2>&1
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
trap 'code=$?; echo BROWSER_PREPARE_FAILED_CODE=$code > /dev/hvc0; journalctl --no-pager -n 100 -u browser-profile.service -u browser-config.service -u browser-session.service -u browser-ready.service > /dev/hvc0 2>&1' ERR
mkdir -p /mnt/browser-seed
mount -o ro /dev/vdc /mnt/browser-seed
build_epoch=$(cat /mnt/browser-seed/build-utc-epoch)
[[ "$build_epoch" =~ ^[0-9]{10}$ ]]
date -u -s "@$build_epoch"
resize2fs /dev/vda
# Direct VZ kernel boot does not use flash firmware installation hooks.
# apt authenticates Ubuntu InRelease metadata and downloaded package hashes.
kernel_version=7.0.0-38-generic
apt-get -o Acquire::AllowInsecureRepositories=false -o Acquire::AllowDowngradeToInsecureRepositories=false update
apt-get purge -y flash-kernel
apt-get -o APT::Get::AllowUnauthenticated=false install -y --no-install-recommends \
  "linux-image-$kernel_version" xserver-xorg-core xserver-xorg-input-libinput \
  xinit xauth x11-utils x11-xserver-utils openbox dbus-x11 scrot \
  libgtk-3-0 libasound2t64 libdbus-glib-1-2 libxt6 libgbm1 libdrm2 \
  libnss3 libnspr4 libx11-xcb1 locales fonts-noto-cjk fonts-dejavu-core \
  ca-certificates apparmor
python3 - "$kernel_version" <<'PY'
import json
import subprocess
import sys

abi = sys.argv[1]
packages = []
for name in ("linux-image-" + abi, "linux-modules-" + abi):
    fields = subprocess.check_output(
        ["dpkg-query", "-W", "-f=${Package}\t${Version}\t${Architecture}\t${Status}\n", name],
        text=True,
    ).strip().split("\t")
    if len(fields) != 4 or fields[0] != name or fields[2] != "arm64" or fields[3] != "install ok installed":
        raise RuntimeError("browser_kernel_package_not_installed:" + name)
    policy = subprocess.check_output(["apt-cache", "policy", name], text=True)
    packages.append({"name": name, "version": fields[1], "architecture": fields[2], "apt_policy": policy})
print("BROWSER_KERNEL_PROVENANCE_BEGIN")
print(json.dumps({"schema": "browser-kernel-packages/v1", "abi": abi, "packages": packages}))
print("BROWSER_KERNEL_PROVENANCE_END", flush=True)
PY
printf 'virtio_gpu\n' > /etc/modules-load.d/browser.conf
echo 'ja_JP.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen ja_JP.UTF-8
update-locale LANG=ja_JP.UTF-8
timedatectl set-timezone Asia/Tokyo
printf 'Asia/Tokyo\n' > /etc/timezone
groupadd -g 59998 browser
useradd -u 59998 -g browser -d /home/browser -m -s /bin/sh browser
passwd -l browser
chmod 0700 /home/browser
install -d -m 0755 /opt/browser /opt/firefox
tar -xJf /mnt/browser-seed/firefox.txz -C /opt
tar -xf /mnt/browser-seed/runtime.tar -C /opt/browser
chown -R root:root /opt/browser /opt/firefox
install -d -m 0755 /opt/firefox/distribution /opt/firefox/defaults/pref
install -m 0644 /opt/browser/policies.json /opt/firefox/distribution/policies.json
install -m 0644 /opt/browser/browser.cfg /opt/firefox/browser.cfg
install -m 0644 /opt/browser/local-settings.js /opt/firefox/defaults/pref/local-settings.js
rm -f /etc/apparmor.d/browser-firefox
install -m 0644 /opt/browser/firefox.apparmor /etc/apparmor.d/firefox
apparmor_parser -r /etc/apparmor.d/firefox
chmod -R go-w /opt/browser /opt/firefox
chmod 0755 /opt/browser/*.sh /opt/browser/proxy.py
python3 /opt/browser/openbox-config.py
install -m 0644 /opt/browser/*.service /etc/systemd/system/
install -d -m 0755 /etc/systemd/logind.conf.d /etc/systemd/journald.conf.d
printf '[Login]\nHandlePowerKey=poweroff\nPowerKeyIgnoreInhibited=yes\n' > /etc/systemd/logind.conf.d/browser.conf
printf '[Journal]\nStorage=volatile\n' > /etc/systemd/journald.conf.d/browser.conf
systemctl disable --now ssh.service ssh.socket apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable systemd-networkd.service systemd-networkd.socket systemd-resolved.service
systemctl mask serial-getty@hvc0.service getty@tty1.service
rm -f /etc/netplan/*.yaml /etc/ssh/ssh_host_*
touch /etc/cloud/cloud-init.disabled
systemctl daemon-reload
systemctl enable browser-config.service browser-profile.service browser-proxy.service browser-session.service browser-ready.service browser-verify.service
# Build dependency downloads are complete. The old preparation kernel only
# installs the GUI; Firefox starts after a fresh boot with the exported HWE Image.
for interface in /sys/class/net/*; do
  [ "${interface##*/}" = lo ] || ip link set "${interface##*/}" down
done
# Template contains no browsing profile/history/login data. The application
# clones it once, and the clone retains the user's future profile thereafter.
rm -rf /home/browser/.mozilla /home/browser/.cache /home/browser/.config
rm -f /home/browser/.browser-build-persistence
dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' > /opt/browser/packages.tsv
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/* /var/lib/cloud/*
cloud-init clean --logs --seed
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id /var/lib/systemd/random-seed
find /var/log -type f -exec truncate -s 0 {} \;
rm -f /root/.Xauthority /root/.bash_history /home/browser/.bash_history
[ -f "/boot/vmlinuz-$kernel_version" ]
[ -f "/boot/initrd.img-$kernel_version" ]
python3 /opt/browser/export-public.py / "$kernel_version"
umount /mnt/browser-seed
echo BROWSER_BASE_READY > /dev/hvc0
sync
systemctl poweroff
