#!/bin/bash
set -euo pipefail

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
app_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
sources="$app_root/Sources/ClaudeIsolationPoC"

exec /usr/bin/python3 - "$sources" "$app_root" "$script_dir" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sources, app_root, script_dir = map(Path, sys.argv[1:])
with tempfile.TemporaryDirectory(prefix="reissue-local-runtime-checks.") as temporary:
    root = Path(temporary)
    binary = root / "reissue-local-runtime-checks"
    environment = dict(os.environ, TMPDIR=temporary)
    commands = [
        ["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-D", "REISSUE_RUNTIME_TESTING",
         "-module-name", "ReissueLocalRuntimeChecksHarness",
         "-module-cache-path", str(root / "module-cache"),
         str(sources / "RuntimePackageCore.swift"), str(sources / "LocalRuntimePackage.swift"),
         str(sources / "RuntimePackageStore.swift"), str(app_root / "tools/reissue_local_runtime.swift"),
         str(script_dir / "ReissueLocalRuntimeChecks.swift"), "-o", str(binary)],
        [str(binary)],
    ]
    try:
        for command in commands:
            result = subprocess.run(command, env=environment, timeout=120, check=False)
            if result.returncode:
                raise SystemExit(result.returncode if result.returncode > 0 else 128 - result.returncode)
    except subprocess.TimeoutExpired:
        print("FAIL reissue_runtime_checks_timeout", file=sys.stderr)
        raise SystemExit(124)
PY
