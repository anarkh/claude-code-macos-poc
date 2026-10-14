#!/bin/sh
set -eu
# Xorg owns the display; only the unprivileged browser account is admitted.
/usr/bin/xhost +SI:localuser:browser
exec /usr/sbin/runuser -u browser -- /usr/bin/env DISPLAY=:0 LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8 TZ=Asia/Tokyo /usr/bin/dbus-run-session /opt/browser/start-session.sh
