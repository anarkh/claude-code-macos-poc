#!/bin/sh
set -eu
# Report readiness only after a visible normal Firefox window exists.
for attempt in $(seq 1 60); do
  if /usr/bin/pgrep -u browser -x 'firefox|firefox-bin' >/dev/null &&
     /usr/bin/xprop -display :0 -root _NET_CLIENT_LIST 2>/dev/null | /bin/grep -q '0x'; then
    for window in $(/usr/bin/xprop -display :0 -root _NET_CLIENT_LIST | /usr/bin/sed 's/.*# //' | /usr/bin/tr ',' ' '); do
      if /usr/bin/xprop -display :0 -id "$window" WM_CLASS 2>/dev/null | /bin/grep -qi firefox; then
        echo BROWSER_SESSION_READY > /dev/hvc0
        exit 0
      fi
    done
  fi
  /usr/bin/sleep 1
done
echo BROWSER_SESSION_FAILED > /dev/hvc0
if /bin/grep -q 'browser.verify=1' /proc/cmdline; then
  /usr/bin/journalctl --no-pager -u browser-session.service -n 80 > /dev/hvc0
fi
exit 1
