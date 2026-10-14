import Darwin
import Foundation

/// Temporary files and fake keys only; these checks never read user credentials or access Keychain.
func localCredentialStoreChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("local_credentials_" + name, passed)) }
    func expectFailure(_ name: String, _ expected: LocalCredentialFailure, operation: () throws -> Void) {
        do { try operation(); check(name, false) }
        catch let failure as LocalCredentialFailure { check(name, failure == expected && !failure.message.isEmpty) }
        catch { check(name, false) }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-credentials-checks-\(UUID().uuidString)", isDirectory: true)
    let directory = root.appendingPathComponent("Credentials", isDirectory: true)
    let translation = FileCredentialStore(scope: .translation, directoryURL: directory)
    let execution = FileCredentialStore(scope: .execution, directoryURL: directory)
    let oldKey = "fake-local-credential-translation"
    let newKey = "fake-local-credential-updated"
    let executionKey = "fake-local-credential-execution"
    do {
        check("missing_load_returns_nil", try translation.load() == nil)
        check("missing_load_does_not_create_directory", !FileManager.default.fileExists(atPath: directory.path))
        try translation.save(oldKey)
        try execution.save(executionKey)
        check("save_updates_missing_cache", try translation.load() == oldKey)
        check("scopes_have_different_files", translation.fileURL.lastPathComponent == "translation-key.json" && execution.fileURL.lastPathComponent == "execution-key.json")
        check("execution_scope_is_independent", try execution.load() == executionKey)
        let oldBytes = try Data(contentsOf: translation.fileURL)
        let executionBytes = try Data(contentsOf: execution.fileURL)
        let payload = try JSONSerialization.jsonObject(with: oldBytes) as! [String: Any]
        check("file_contains_only_version_and_key", Set(payload.keys) == ["schemaVersion", "apiKey"] && payload["schemaVersion"] as? Int == 1 && payload["apiKey"] as? String == oldKey)
        check("directory_is_owner_only", (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        check("translation_file_is_owner_only", (try FileManager.default.attributesOfItem(atPath: translation.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        check("execution_file_is_owner_only", (try FileManager.default.attributesOfItem(atPath: execution.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let restarted = FileCredentialStore(scope: .translation, directoryURL: directory)
        check("restart_restores_saved_key", try restarted.load() == oldKey)
        try FileManager.default.removeItem(at: translation.fileURL)
        check("loaded_cache_survives_source_removal", try restarted.load() == oldKey)
        check("new_instance_observes_removed_file", try FileCredentialStore(scope: .translation, directoryURL: directory).load() == nil)
        try restarted.save(newKey)
        check("save_updates_loaded_cache", try restarted.load() == newKey)
        check("save_updates_restart_value", try FileCredentialStore(scope: .translation, directoryURL: directory).load() == newKey)
        check("translation_update_keeps_execution_bytes", try Data(contentsOf: execution.fileURL) == executionBytes)
        try translation.save(oldKey)

        let failing = FileCredentialStore(scope: .translation, directoryURL: directory, atomicReplace: { _, _ in throw LocalCredentialFailure.saveFailed })
        check("atomic_test_initial_cache_loaded", try failing.load() == oldKey)
        expectFailure("atomic_replace_failure_reported", .saveFailed) { try failing.save(newKey) }
        check("atomic_failure_preserves_disk_bytes", try Data(contentsOf: translation.fileURL) == oldBytes)
        check("atomic_failure_preserves_cache", try failing.load() == oldKey)
        check("atomic_failure_cleans_temporary_file", try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["translation-key.json", "execution-key.json"])

        func malformed(_ name: String, _ bytes: Data, _ expected: LocalCredentialFailure) throws {
            try bytes.write(to: translation.fileURL)
            let fresh = FileCredentialStore(scope: .translation, directoryURL: directory)
            expectFailure(name + "_load", expected) { _ = try fresh.load() }
            expectFailure(name + "_save_blocked", expected) { try fresh.save(newKey) }
            check(name + "_old_bytes_preserved", try Data(contentsOf: translation.fileURL) == bytes)
            try oldBytes.write(to: translation.fileURL)
            check(name + "_failed_load_is_not_cached", try fresh.load() == oldKey)
        }
        try malformed("invalid_json", Data("not-json".utf8), .invalidFormat)
        try malformed("future_version", try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "apiKey": oldKey]), .unsupportedVersion)
        try malformed("unknown_field", try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "apiKey": oldKey, "other": "ignored"]), .invalidFormat)
        try malformed("missing_key", try JSONSerialization.data(withJSONObject: ["schemaVersion": 1]), .invalidFormat)
        try malformed("wrong_key_type", try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "apiKey": 42]), .invalidFormat)
        try malformed("boolean_version", try JSONSerialization.data(withJSONObject: ["schemaVersion": true, "apiKey": oldKey]), .invalidFormat)
        try malformed("invalid_utf8", Data([0xFF, 0xFE, 0x80]), .invalidFormat)
        try malformed("invalid_persisted_key", try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "apiKey": "tiny"]), .invalidKey)
        try malformed("oversized_file", Data(repeating: 32, count: FileCredentialStore.maximumBytes + 1), .fileTooLarge)

        try Data("corrupt-after-first-load".utf8).write(to: translation.fileURL)
        check("cached_load_does_not_reopen_corrupt_file", try translation.load() == oldKey)
        expectFailure("cached_save_rechecks_corrupt_disk", .invalidFormat) { try translation.save(newKey) }
        check("failed_save_keeps_old_loaded_cache", try translation.load() == oldKey)
        try translation.delete()
        check("explicit_delete_can_clear_corrupt_regular_file", !FileManager.default.fileExists(atPath: translation.fileURL.path))
        check("delete_clears_cache", try translation.load() == nil)
        check("delete_keeps_other_scope_file", try Data(contentsOf: execution.fileURL) == executionBytes)
        check("delete_keeps_other_scope_cache", try execution.load() == executionKey)
        try translation.delete()
        check("deleting_missing_file_succeeds", try translation.load() == nil)
        try translation.save(oldKey)

        let linkTarget = root.appendingPathComponent("unrelated.json")
        try oldBytes.write(to: linkTarget)
        try FileManager.default.removeItem(at: translation.fileURL)
        try FileManager.default.createSymbolicLink(at: translation.fileURL, withDestinationURL: linkTarget)
        let linked = FileCredentialStore(scope: .translation, directoryURL: directory)
        expectFailure("symbolic_link_load_rejected", .readFailed) { _ = try linked.load() }
        expectFailure("symbolic_link_save_rejected", .readFailed) { try linked.save(newKey) }
        expectFailure("symbolic_link_delete_rejected", .deleteFailed) { try linked.delete() }
        check("symbolic_link_target_unchanged", try Data(contentsOf: linkTarget) == oldBytes)
        expectFailure("failed_delete_keeps_cached_value", .deleteFailed) { try translation.delete() }
        check("delete_failure_preserves_cache", try translation.load() == oldKey)
        try FileManager.default.removeItem(at: translation.fileURL)
        try translation.save(oldKey)

        let linkedDirectory = root.appendingPathComponent("linked-directory", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: directory)
        let directoryLinkStore = FileCredentialStore(scope: .translation, directoryURL: linkedDirectory)
        expectFailure("symbolic_link_directory_load_rejected", .readFailed) { _ = try directoryLinkStore.load() }
        expectFailure("symbolic_link_directory_save_rejected", .readFailed) { try directoryLinkStore.save(newKey) }
        expectFailure("symbolic_link_directory_delete_rejected", .deleteFailed) { try directoryLinkStore.delete() }
        check("symbolic_link_directory_target_unchanged", try Data(contentsOf: translation.fileURL) == oldBytes)
        let nonFileStore = FileCredentialStore(scope: .translation, directoryURL: URL(string: "https://example.invalid/credentials")!)
        expectFailure("remote_url_rejected", .readFailed) { _ = try nonFileStore.load() }
        let nonDirectory = root.appendingPathComponent("not-a-directory")
        try Data("ordinary-file".utf8).write(to: nonDirectory)
        let nonDirectoryStore = FileCredentialStore(scope: .translation, directoryURL: nonDirectory)
        expectFailure("file_used_as_directory_rejected", .readFailed) { _ = try nonDirectoryStore.load() }
        try FileManager.default.removeItem(at: translation.fileURL)
        try FileManager.default.createDirectory(at: translation.fileURL, withIntermediateDirectories: false)
        let directoryFileStore = FileCredentialStore(scope: .translation, directoryURL: directory)
        expectFailure("directory_used_as_file_rejected", .readFailed) { _ = try directoryFileStore.load() }
        expectFailure("directory_used_as_file_delete_rejected", .deleteFailed) { try directoryFileStore.delete() }
        try FileManager.default.removeItem(at: translation.fileURL)

        for (name, key) in [
            ("empty", ""), ("too_short", String(repeating: "a", count: 15)),
            ("too_long", String(repeating: "a", count: 513)), ("ascii_space", "fake-invalid key-value"),
            ("newline", "fake-invalid\nkey-value"), ("tab", "fake-invalid\tkey-value"),
            ("null", "fake-invalid\u{0}key-value"), ("delete_control", "fake-invalid\u{7F}key-value"),
            ("unicode_space", "fake-invalid\u{A0}key-value"), ("unicode_control", "fake-invalid\u{85}key-value"),
            ("utf8_bytes_too_long", String(repeating: "中", count: 171))
        ] {
            expectFailure("key_" + name + "_rejected", .invalidKey) { try translation.save(key) }
            check("key_" + name + "_does_not_create_file", !FileManager.default.fileExists(atPath: translation.fileURL.path))
        }
        try translation.save(String(repeating: "a", count: 16))
        check("exact_16_byte_key_allowed", try translation.load() == String(repeating: "a", count: 16))
        try translation.save(String(repeating: "a", count: 512))
        check("exact_512_byte_key_allowed", try translation.load() == String(repeating: "a", count: 512))
        try translation.save(String(repeating: "中", count: 6))
        check("minimum_counts_utf8_bytes", try translation.load() == String(repeating: "中", count: 6))
        check("error_messages_do_not_disclose_keys", !LocalCredentialFailure.invalidKey.message.contains(oldKey) && !LocalCredentialFailure.saveFailed.message.contains(newKey))

        let cacheDirectory = root.appendingPathComponent("missing-cache", isDirectory: true)
        let initiallyMissing = FileCredentialStore(scope: .execution, directoryURL: cacheDirectory)
        check("missing_cache_initial_nil", try initiallyMissing.load() == nil)
        try FileCredentialStore(scope: .execution, directoryURL: cacheDirectory).save(executionKey)
        check("missing_result_is_cached_for_instance", try initiallyMissing.load() == nil)
        check("new_instance_reads_newly_saved_file", try FileCredentialStore(scope: .execution, directoryURL: cacheDirectory).load() == executionKey)
        try initiallyMissing.save(newKey)
        check("save_replaces_missing_cache", try initiallyMissing.load() == newKey)

        let memory = MemoryAppCredentialStore()
        check("memory_store_starts_empty", try memory.load() == nil)
        try memory.save(oldKey)
        check("memory_store_saves_without_file", try memory.load() == oldKey && memory.saveCount == 1)
        memory.saveFailure = .saveFailed
        expectFailure("memory_save_failure_reported", .saveFailed) { try memory.save(newKey) }
        check("memory_save_failure_preserves_key", try memory.load() == oldKey && memory.saveCount == 1)
        memory.deleteFailure = .deleteFailed
        expectFailure("memory_delete_failure_reported", .deleteFailed) { try memory.delete() }
        check("memory_delete_failure_preserves_key", try memory.load() == oldKey)
        memory.deleteFailure = nil
        try memory.delete()
        check("memory_delete_clears_key", try memory.load() == nil && memory.deleteCount == 1)
        memory.loadFailure = .readFailed
        expectFailure("memory_load_failure_reported", .readFailed) { _ = try memory.load() }
        try FileManager.default.removeItem(at: root)
        check("temporary_directory_removed", !FileManager.default.fileExists(atPath: root.path))
    } catch {
        check("setup_or_operation_failure", false)
        if FileManager.default.fileExists(atPath: root.path) {
            do { try FileManager.default.removeItem(at: root) }
            catch { check("failed_cleanup", false) }
        }
    }
    return results
}
