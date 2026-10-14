#!/bin/bash
set -euo pipefail
host_root=$(cd "$(dirname "$0")/.." && pwd)
swift build --package-path "$host_root" -c release --product vm-text-runtime
codesign --force --sign - --entitlements "$host_root/virtualization.entitlements" "$host_root/.build/release/vm-text-runtime"
codesign --verify --strict "$host_root/.build/release/vm-text-runtime"
"$host_root/.build/release/vm-text-runtime" preflight
