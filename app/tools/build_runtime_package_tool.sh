#!/bin/bash
set -euo pipefail
tool_root=$(cd "$(dirname "$0")" && pwd)
app_root=$(cd "$tool_root/.." && pwd)
output=${1:-"$app_root/.build/runtime-package-tool"}
if [ "${output:0:1}" != "/" ]; then
  echo 'Supply an absolute output path.' >&2
  exit 2
fi
mkdir -p "$(dirname "$output")"
swiftc -O -target arm64-apple-macosx14.0 \
  "$app_root/Sources/ClaudeIsolationPoC/RuntimePackageCore.swift" \
  "$app_root/tools/RuntimePackageTool.swift" \
  -o "$output"
printf '%s\n' "$output"
