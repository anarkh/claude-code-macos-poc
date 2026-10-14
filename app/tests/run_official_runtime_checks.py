#!/usr/bin/env python3
"""Build two focused Swift harnesses from immutable task-owned source snapshots."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def digest(data):
    return hashlib.sha256(data).hexdigest()


def segment(text, start, end):
    if text.count(start) != 1:
        raise ValueError("source declaration boundary is not unique")
    beginning = text.index(start)
    ending = text.find(end, beginning + len(start))
    if ending < 0:
        raise ValueError("source declaration ending is missing")
    return text[beginning:ending].rstrip() + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not args.output.is_absolute():
        parser.error("--output must be an absolute task-owned path")
    repo = Path(__file__).resolve().parents[2]
    sources = repo / "app/Sources/ClaudeIsolationPoC"
    output = args.output
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    frozen = output / "sources"
    frozen.mkdir(mode=0o700)
    names = ["RuntimePackageCore.swift", "RuntimePackageStore.swift", "LocalRuntimePackage.swift",
             "OfficialRuntimeUpdateService.swift", "NetworkConfiguration.swift", "RuntimeProfile.swift",
             "NetworkFailure.swift", "RuntimeFailure.swift", "VMRuntimeFailure.swift",
             "RuntimeUpdateConfiguration.swift", "RuntimeUpdateService.swift", "RuntimeVersionModel.swift",
             "OfficialRuntimeVersionChecks.swift", "TranslationModel.swift", "ChatExecution.swift",
             "ApplicationTermination.swift"]
    hashes = {}
    for name in names:
        payload = (sources / name).read_bytes()
        (frozen / name).write_bytes(payload)
        hashes[name] = digest(payload)
    driver_name = "OfficialRuntimeIntegration.swift"
    driver_bytes = (repo / "app/tests" / driver_name).read_bytes()
    (frozen / driver_name).write_bytes(driver_bytes)
    hashes[driver_name] = digest(driver_bytes)
    translation = (frozen / "TranslationModel.swift").read_text()
    chat = (frozen / "ChatExecution.swift").read_text()
    termination = (frozen / "ApplicationTermination.swift").read_text()
    version_model = (frozen / "RuntimeVersionModel.swift").read_text()
    support = "import Foundation\nimport Darwin\n\n" + "\n".join([
        segment(translation, "enum TranslationFailure:", "protocol TranslationProviding:"),
        segment(translation, "struct AppConfiguration:", "struct StdioTranslationProvider:"),
        segment(chat, "enum ChatFailure:", "protocol ChatProviding:"),
        segment(chat, "enum LoginResetLifecycleFailure:", "/// Validates each event"),
        segment(termination, "enum ApplicationTerminationFailure:", "/// One admission barrier"),
    ])
    common = names[:9]
    integration_support = support + "\n" + segment(version_model, "enum RuntimePackageEnvironment", "@MainActor")
    (frozen / "IntegrationSourceSupport.swift").write_text(integration_support)
    (frozen / "ModelSourceSupport.swift").write_text(support)
    (frozen / "OfficialRuntimeChecksMain.swift").write_text('''import Foundation
import Darwin
@main struct OfficialRuntimeChecksMain {
    @MainActor static func main() async {
        let checks = await officialRuntimeVersionChecks()
        let ok = !checks.isEmpty && checks.values.allSatisfy { $0 }
        let result: [String: Any] = ["schema": "official-runtime-model-checks/v1", "ok": ok,
                                   "real_provider": false, "checks": checks]
        do { print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)) }
        catch { print("{\\\"ok\\\":false,\\\"code\\\":\\\"CHECK_OUTPUT_FAILED\\\"}"); exit(1) }
        if !ok { exit(1) }
    }
}
''')
    builds = {}
    targets = {
        "OfficialRuntimeIntegration": common + ["IntegrationSourceSupport.swift", driver_name],
        "OfficialRuntimeModelChecks": common + ["RuntimeUpdateConfiguration.swift", "RuntimeUpdateService.swift",
                                                 "RuntimeVersionModel.swift", "OfficialRuntimeVersionChecks.swift",
                                                 "ModelSourceSupport.swift", "OfficialRuntimeChecksMain.swift"],
    }
    for target, inputs in targets.items():
        command = ["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-target", "arm64-apple-macosx14.0",
                   "-module-name", target] + [str(frozen / name) for name in inputs] + ["-o", str(output / target)]
        completed = subprocess.run(command, capture_output=True, timeout=180)
        (output / (target + ".compiler.txt")).write_bytes(completed.stdout + completed.stderr)
        builds[target] = {"returncode": completed.returncode, "inputs": inputs,
                          "diagnosticBytes": len(completed.stdout) + len(completed.stderr),
                          "diagnosticSHA256": digest(completed.stdout + completed.stderr)}
        if completed.returncode == 0:
            builds[target]["binarySHA256"] = digest((output / target).read_bytes())
        else:
            print(completed.stderr.decode(errors="replace")[-6000:], file=sys.stderr)
            break
    all_built = len(builds) == len(targets) and all(value["returncode"] == 0 for value in builds.values())
    checks = None
    if all_built:
        completed = subprocess.run([str(output / "OfficialRuntimeModelChecks")], capture_output=True, timeout=30)
        checks = json.loads(completed.stdout)
        checks["returncode"] = completed.returncode
        if completed.stderr:
            checks["diagnosticBytes"] = len(completed.stderr)
            checks["diagnosticSHA256"] = digest(completed.stderr)
    exact = all(digest((sources / name).read_bytes()) == hashes[name] for name in names)
    exact = exact and digest((repo / "app/tests" / driver_name).read_bytes()) == hashes[driver_name]
    result = {"schema": "official-runtime-focused-validation/v1", "real_provider": False,
              "ok": all_built and checks is not None and checks.get("ok") is True and exact,
              "sourceSHA256": hashes, "sourceSnapshotStillEqual": exact, "builds": builds, "model": checks,
              "generatedSupportSHA256": {"integration": digest(integration_support.encode()), "model": digest(support.encode())}}
    result_file = output / "validation-result.json"
    result_file.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    if json.loads(result_file.read_text()) != result:
        raise ValueError("validation evidence readback mismatch")
    print(json.dumps({"ok": result["ok"], "modelChecks": len(checks.get("checks", {})) if checks else 0,
                      "evidence": str(result_file)}, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
