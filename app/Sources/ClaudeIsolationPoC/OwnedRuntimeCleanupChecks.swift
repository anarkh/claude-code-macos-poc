import Darwin
import Foundation

func ownedRuntimeCleanupChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("owned_runtime_cleanup_" + name, passed)) }
    let manager = FileManager.default
    guard let physical = realpath(manager.temporaryDirectory.path, nil) else { return [("owned_runtime_cleanup_physical_temp", false)] }
    let fixture = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("owned-runtime-checks-" + UUID().uuidString)
    free(physical)
    do { try manager.createDirectory(at: fixture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    catch { return [("owned_runtime_cleanup_fixture_setup", false)] }
    var sequence = 0
    func scope() throws -> URL {
        sequence += 1
        let root = fixture.appendingPathComponent("case-\(sequence)")
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    func makeRun(_ root: URL, name: String = "claude-deepseek-chat-ABC123",
                 change: (inout [String: Any]) -> Void = { _ in }) throws -> URL {
        let run = root.appendingPathComponent(name)
        try manager.createDirectory(at: run, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(run.path, &info) == 0 else { throw OwnedRuntimeCleanupFailure.invalidDirectory }
        var manifest: [String: Any] = ["schema": "claude-isolation-owned-run/v1", "run_id": UUID().uuidString,
            "uid": getuid(), "pid": 12_345, "kind": name.hasPrefix("claude-deepseek-text-") ? "text-smoke" : "chat",
            "directory_dev": String(UInt32(bitPattern: info.st_dev)), "directory_ino": String(info.st_ino),
            "native_state": "not-started", "native_pid": NSNull()]
        change(&manifest)
        let receipt = run.appendingPathComponent(OwnedRuntimeCleanupService.manifestName)
        try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys).write(to: receipt)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        return run
    }
    func service(_ root: URL) -> OwnedRuntimeCleanupService { .init(tempRoot: root, processAlive: { _ in false }) }
    func exists(_ path: URL) -> Bool { manager.fileExists(atPath: path.path) }
    do {
        let root = try scope()
        let run = try makeRun(root)
        let nested = run.appendingPathComponent("home/.claude")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("fake-session".utf8).write(to: nested.appendingPathComponent("session.json"))
        let unrelated = root.appendingPathComponent("claude-unrelated")
        try Data("preserve".utf8).write(to: unrelated)
        let cleanup = service(root), snapshot = try cleanup.scan()
        check("valid_inactive_is_eligible", snapshot.eligibleCount == 1 && !snapshot.hasBlockingRuns)
        let result = cleanup.cleanup(snapshot)
        check("valid_inactive_removed", result.deletedCount == 1 && result.failedCount == 0 && !exists(run))
        check("unrelated_preserved", exists(unrelated))
        check("repeat_scan_empty", try cleanup.scan().items.isEmpty)
    } catch { check("valid_inactive_setup", false) }

    for (name, mutate) in [
        ("unknown_schema", { (m: inout [String: Any]) in m["schema"] = "claude-isolation-owned-run/v2" }),
        ("unknown_field", { (m: inout [String: Any]) in m["token"] = "fake" }),
        ("wrong_uid", { (m: inout [String: Any]) in m["uid"] = getuid() + 1 }),
        ("wrong_inode", { (m: inout [String: Any]) in m["directory_ino"] = "1" }),
        ("wrong_device", { (m: inout [String: Any]) in m["directory_dev"] = "0" }),
        ("wrong_kind", { (m: inout [String: Any]) in m["kind"] = "text-smoke" }),
        ("invalid_run_id", { (m: inout [String: Any]) in m["run_id"] = "../other" }),
        ("invalid_pid", { (m: inout [String: Any]) in m["pid"] = 0 }),
        ("missing_native_pid", { (m: inout [String: Any]) in m["native_state"] = "registered" }),
    ] {
        do {
            let root = try scope(), run = try makeRun(root, change: mutate), cleanup = service(root)
            let snapshot = try cleanup.scan()
            check(name + "_manual", snapshot.manualCount == 1 && snapshot.eligibleCount == 0)
            check(name + "_retained", cleanup.cleanup(snapshot).deletedCount == 0 && exists(run))
        } catch { check(name + "_setup", false) }
    }
    for state in ["missing", "corrupt", "oversized", "public_permissions"] {
        do {
            let root = try scope(), run = try makeRun(root), receipt = run.appendingPathComponent(OwnedRuntimeCleanupService.manifestName)
            switch state {
            case "missing": try manager.removeItem(at: receipt)
            case "corrupt": try Data("{invalid".utf8).write(to: receipt)
            case "oversized": try Data(repeating: 32, count: 4_097).write(to: receipt)
            default: try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: receipt.path)
            }
            let cleanup = service(root), snapshot = try cleanup.scan()
            check(state + "_manual_retained", snapshot.manualCount == 1 && cleanup.cleanup(snapshot).deletedCount == 0 && exists(run))
        } catch { check(state + "_setup", false) }
    }
    for (name, owner, native, alive) in [("owner", Int32(12_345), Int32(23_456), Int32(12_345)),
        ("native", 12_345, 23_456, 23_456), ("native_group", 12_345, 23_456, -23_456)] {
        do {
            let root = try scope(), run = try makeRun(root) { m in m["pid"] = owner; m["native_state"] = "registered"; m["native_pid"] = native }
            let cleanup = OwnedRuntimeCleanupService(tempRoot: root, processAlive: { $0 == alive }), snapshot = try cleanup.scan()
            check(name + "_active_blocks", snapshot.hasActiveOwnedRuns && snapshot.hasBlockingRuns && snapshot.eligibleCount == 0)
            check(name + "_active_retained", cleanup.cleanup(snapshot).activeCount == 1 && exists(run))
        } catch { check(name + "_setup", false) }
    }
    do {
        let root = try scope(), run = try makeRun(root) { $0["native_state"] = "pending" }, cleanup = service(root)
        let snapshot = try cleanup.scan()
        check("uncertain_launch_blocks", snapshot.hasBlockingRuns && snapshot.manualCount == 1)
        check("uncertain_launch_retained", cleanup.cleanup(snapshot).hasBlockingRuns && exists(run))
    } catch { check("uncertain_setup", false) }
    do {
        let root = try scope(), run = try makeRun(root) { $0["pid"] = getpid() }
        let snapshot = try OwnedRuntimeCleanupService(tempRoot: root).scan()
        check("real_current_pid_blocks", snapshot.hasActiveOwnedRuns && exists(run))
    } catch { check("real_pid_setup", false) }

    do {
        let root = try scope(), run = try makeRun(root), target = fixture.appendingPathComponent("symlink-target")
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        let marker = target.appendingPathComponent("preserve.txt")
        try Data("preserve".utf8).write(to: marker)
        try manager.createSymbolicLink(at: run.appendingPathComponent("outside"), withDestinationURL: target)
        let cleanup = service(root)
        check("nested_symlink_unlinked_without_follow", cleanup.cleanup(try cleanup.scan()).deletedCount == 1 && exists(marker))
        let rootLink = root.appendingPathComponent("claude-deepseek-chat-DEF456")
        try manager.createSymbolicLink(at: rootLink, withDestinationURL: target)
        let snapshot = try cleanup.scan()
        check("root_symlink_manual", snapshot.manualCount == 1 && cleanup.cleanup(snapshot).deletedCount == 0 && exists(marker))
    } catch { check("symlink_setup", false) }
    do {
        let root = try scope(), run = try makeRun(root), receipt = run.appendingPathComponent(OwnedRuntimeCleanupService.manifestName)
        let external = fixture.appendingPathComponent("external-receipt")
        try manager.moveItem(at: receipt, to: external)
        try manager.createSymbolicLink(at: receipt, withDestinationURL: external)
        let cleanup = service(root)
        check("manifest_symlink_retained", cleanup.cleanup(try cleanup.scan()).manualCount == 1 && exists(external) && exists(run))
    } catch { check("manifest_symlink_setup", false) }
    do {
        let root = try scope(), link = fixture.appendingPathComponent("ancestor-link")
        _ = try makeRun(root)
        try manager.createSymbolicLink(at: link, withDestinationURL: root)
        do { _ = try service(link).scan(); check("ancestor_symlink_rejected", false) }
        catch { check("ancestor_symlink_rejected", true) }
    } catch { check("ancestor_setup", false) }
    do {
        let root = try scope(), run = try makeRun(root), cleanup = service(root), snapshot = try cleanup.scan()
        let saved = root.appendingPathComponent("original-retained")
        try manager.moveItem(at: run, to: saved)
        let replacement = try makeRun(root)
        check("scan_to_delete_replacement_retained", cleanup.cleanup(snapshot).failedCount == 1 && exists(saved) && exists(replacement))
    } catch { check("replacement_setup", false) }
    do {
        let root = try scope(), run = try makeRun(root), cleanup = service(root), snapshot = try cleanup.scan()
        let receipt = run.appendingPathComponent(OwnedRuntimeCleanupService.manifestName)
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as! [String: Any]
        manifest["run_id"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: manifest).write(to: receipt)
        check("scan_to_delete_manifest_change_retained", cleanup.cleanup(snapshot).failedCount == 1 && exists(run))
    } catch { check("manifest_change_setup", false) }
    do {
        let root = try scope(), run = try makeRun(root), cleanup = service(root), snapshot = try cleanup.scan()
        let moved = fixture.appendingPathComponent("parent-retained")
        try manager.moveItem(at: root, to: moved)
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        check("parent_identity_change_rejected", cleanup.cleanup(snapshot).failedCount == 1 && exists(moved.appendingPathComponent(run.lastPathComponent)))
    } catch { check("parent_change_setup", false) }
    do {
        let root = try scope(), run = try makeRun(root, name: "claude-deepseek-text-cleanup-" + UUID().uuidString.lowercased()), cleanup = service(root)
        check("quarantined_root_rediscovered", try cleanup.scan().eligibleCount == 1)
        check("quarantined_root_recoverable", cleanup.cleanup(try cleanup.scan()).deletedCount == 1 && !exists(run))
    } catch { check("quarantine_setup", false) }
    do {
        let root = try scope(), run = try makeRun(root), locked = run.appendingPathComponent("unreadable")
        try manager.createDirectory(at: locked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o000])
        let cleanup = service(root), result = cleanup.cleanup(try cleanup.scan())
        check("deletion_error_reported", result.failedCount == 1 && result.deletedCount == 0)
        let candidates = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let rescanned = try cleanup.scan()
        check("failed_quarantine_remains_discoverable", candidates.count == 1 && rescanned.eligibleCount == 1)
        for candidate in candidates { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.appendingPathComponent("unreadable").path) }
    } catch { check("error_setup", false) }
    do { try manager.removeItem(at: fixture); check("fixture_teardown", true) }
    catch { check("fixture_teardown", false) }
    return results
}
