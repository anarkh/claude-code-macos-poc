#!/bin/bash
set -euo pipefail
tool_root=$(cd "$(dirname "$0")" && pwd)
app_root=$(cd "$tool_root/.." && pwd)
source=${1:-"$app_root/Resources/AppIcon.png"}
output=${2:-"$app_root/.build/AppIcon.icns"}
if [ "${source:0:1}" != "/" ] || [ ! -f "$source" ] || [ "${output:0:1}" != "/" ]; then
  echo 'Supply an existing absolute PNG source path and an absolute ICNS output path.' >&2
  exit 2
fi
properties=$(/usr/bin/sips -g format -g pixelWidth -g pixelHeight "$source")
format=$(printf '%s\n' "$properties" | /usr/bin/awk '/^[[:space:]]*format:/ {print $2}')
width=$(printf '%s\n' "$properties" | /usr/bin/awk '/^[[:space:]]*pixelWidth:/ {print $2}')
height=$(printf '%s\n' "$properties" | /usr/bin/awk '/^[[:space:]]*pixelHeight:/ {print $2}')
if [ "$format" != 'png' ] || ! [[ "$width" =~ ^[0-9]+$ ]] || [ "$width" != "$height" ] || [ "$width" -lt 1024 ]; then
  echo 'App icon must be a square PNG of at least 1024 x 1024 pixels.' >&2
  exit 2
fi
staging_root=$(mktemp -d "${TMPDIR:-/tmp}/claude-app-icon.XXXXXX")
trap 'rm -rf "$staging_root"' EXIT
iconset="$staging_root/AppIcon.iconset"
mkdir -p "$iconset" "$(dirname "$output")"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  /usr/bin/sips -z "$retina_size" "$retina_size" "$source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil --convert icns "$iconset" --output "$output"
printf '%s\n' "$output"
