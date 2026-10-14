#!/bin/bash
# Public build-only root reconstruction. Never used against a profile disk.
set -euo pipefail
exec >/dev/hvc0 2>&1
trap 'code=$?; echo BROWSER_HWE_FAILED_CODE=$code > /dev/hvc0' ERR
mkdir -p /mnt/browser-seed /mnt/browser-root
mount -o ro /dev/vdc /mnt/browser-seed
fs_code=0
if e2fsck -fp /dev/vdb; then
  fs_code=0
else
  fs_code=$?
fi
[ "$fs_code" -le 1 ]
e2fsck -fn /dev/vdb
mount /dev/vdb /mnt/browser-root
target=/mnt/browser-root
tar -xJf /mnt/browser-seed/firefox.txz -C "$target/opt"
tar -xf /mnt/browser-seed/runtime.tar -C "$target/opt/browser"
chown -R root:root "$target/opt/browser" "$target/opt/firefox"
printf 'Asia/Tokyo\n' > "$target/etc/timezone"
ln -sf /usr/share/zoneinfo/Asia/Tokyo "$target/etc/localtime"
chmod -R go-w "$target/opt/browser" "$target/opt/firefox"
chmod 0755 "$target/opt/browser/"*.sh "$target/opt/browser/proxy.py"
install -m 0644 "$target/opt/browser/policies.json" "$target/opt/firefox/distribution/policies.json"
install -m 0644 "$target/opt/browser/browser.cfg" "$target/opt/firefox/browser.cfg"
install -m 0644 "$target/opt/browser/local-settings.js" "$target/opt/firefox/defaults/pref/local-settings.js"
rm -f "$target/etc/apparmor.d/browser-firefox"
install -m 0644 "$target/opt/browser/firefox.apparmor" "$target/etc/apparmor.d/firefox"
install -m 0644 "$target/opt/browser/"*.service "$target/etc/systemd/system/"
printf 'virtio_gpu\n' > "$target/etc/modules-load.d/browser.conf"
touch "$target/etc/cloud/cloud-init.disabled"
systemctl --root="$target" enable browser-config.service browser-profile.service browser-proxy.service browser-session.service browser-ready.service browser-verify.service
systemctl --root="$target" mask serial-getty@hvc0.service getty@tty1.service
for directory in dev proc sys; do mount --rbind "/$directory" "$target/$directory"; mount --make-rslave "$target/$directory"; done
rm -f "$target/etc/resolv.conf"
cp /run/systemd/resolve/resolv.conf "$target/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "$target/usr/sbin/policy-rc.d"
chmod 0755 "$target/usr/sbin/policy-rc.d"
export DEBIAN_FRONTEND=noninteractive
chroot "$target" apt-get update
# Direct VZ kernel boot has no supported flash firmware target. Firmware
# installation hooks are unnecessary; retain normal signed kernel packages.
chroot "$target" apt-get purge -y flash-kernel
chroot "$target" apt-get install -y --no-install-recommends linux-image-7.0.0-38-generic
chroot "$target" dpkg --audit
kernel=7.0.0-38-generic
[ -f "$target/boot/vmlinuz-$kernel" ]
[ -f "$target/boot/initrd.img-$kernel" ]
python3 /mnt/browser-seed/export-public.py "$target" "$kernel"
chroot "$target" dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' > "$target/opt/browser/packages.tsv"
chroot "$target" apt-get clean
rm -f "$target/usr/sbin/policy-rc.d"
printf 'nameserver 127.0.0.1\n' > "$target/etc/resolv.conf"
rm -rf "$target/var/lib/apt/lists/"* "$target/var/cache/apt/"* "$target/var/lib/cloud/"* "$target/var/log/"*
mkdir -p "$target/var/log"
truncate -s 0 "$target/etc/machine-id"
rm -f "$target/var/lib/dbus/machine-id" "$target/var/lib/systemd/random-seed" "$target/root/.Xauthority"
rm -rf "$target/home/browser/.mozilla" "$target/home/browser/.cache" "$target/home/browser/.config"
for directory in sys proc dev; do umount -R "$target/$directory"; done
sync
umount "$target"
e2fsck -fn /dev/vdb
echo BROWSER_HWE_BASE_READY > /dev/hvc0
systemctl poweroff
