#!/bin/sh
set -eu
sdk_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
node_bin=${POC_NODE_BIN:-$(command -v node)}
mkdir -p "$sdk_dir/.install-home" "$sdk_dir/.install-tmp"
exec env -i PATH="$(dirname -- "$node_bin"):/usr/bin:/bin" \
  HOME="$sdk_dir/.install-home" TMPDIR="$sdk_dir/.install-tmp" \
  "$node_bin" "$sdk_dir/prepare-linux-native.mjs"
