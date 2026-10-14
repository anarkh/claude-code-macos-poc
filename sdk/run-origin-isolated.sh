#!/bin/sh
set -eu
sdk_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
node_bin=${POC_NODE_BIN:-$(command -v node)}
mkdir -p "$sdk_dir/.origin-launcher-home" "$sdk_dir/.origin-launcher-tmp"
exec env -i PATH="$(dirname -- "$node_bin"):/usr/bin:/bin:/usr/sbin" HOME="$sdk_dir/.origin-launcher-home" TMPDIR="$sdk_dir/.origin-launcher-tmp" CLAUDE_CONFIG_DIR="$sdk_dir/.origin-launcher-home/.claude" ANTHROPIC_API_KEY=sk-ant-api03-POC-FAKE-NOT-VALID "$node_bin" "$sdk_dir/run-origin-poc.mjs"
