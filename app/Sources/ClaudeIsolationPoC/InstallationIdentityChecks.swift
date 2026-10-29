import Darwin
import Foundation

func installationIdentityChecks() -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { checks.append(("installation_identity_" + name, passed)) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("installation-identity-check-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { check("temporary_state_cleanup", false) }
        }
        let absent = FileInstallationIdentityStore(directoryURL: root.appendingPathComponent("absent"))
        check("read_missing_identity_does_not_create_directory", try absent.loadDeviceID() == nil &&
              !FileManager.default.fileExists(atPath: absent.directoryURL.path))
        try FileManager.default.createDirectory(at: absent.directoryURL, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        check("read_missing_identity_does_not_create_file", try absent.loadDeviceID() == nil &&
              FileManager.default.contentsOfDirectory(atPath: absent.directoryURL.path).isEmpty)
        let createdByReplacement = try absent.replaceDeviceID()
        check("replace_missing_identity_creates_private_identity", try absent.loadDeviceID() == createdByReplacement &&
              ClaudeRequestIdentity.validDeviceID(createdByReplacement))

        let store = FileInstallationIdentityStore(directoryURL: root.appendingPathComponent("first"))
        let deviceID = try store.loadOrCreateDeviceID()
        let reopened = FileInstallationIdentityStore(directoryURL: store.directoryURL)
        let data = try Data(contentsOf: store.fileURL)
        check("reopening_preserves_random_device", try reopened.loadOrCreateDeviceID() == deviceID && ClaudeRequestIdentity.validDeviceID(deviceID))
        check("read_does_not_rewrite_identity", try Data(contentsOf: store.fileURL) == data)
        let second = FileInstallationIdentityStore(directoryURL: root.appendingPathComponent("second"))
        check("separate_installations_are_distinct", try second.loadOrCreateDeviceID() != deviceID)
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        let directoryMode = try FileManager.default.attributesOfItem(atPath: store.directoryURL.path)[.posixPermissions] as? NSNumber
        check("private_permissions", fileMode?.intValue == 0o600 && directoryMode?.intValue == 0o700)
        let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        check("stores_no_credentials_or_machine_details", Set(fields?.keys.map { $0 } ?? []) == ["schemaVersion", "deviceID"])
        check("explicit_read_does_not_rewrite_identity", try store.loadDeviceID() == deviceID &&
              Data(contentsOf: store.fileURL) == data)

        let replacement = try store.replaceDeviceID()
        check("explicit_replacement_changes_device", replacement != deviceID && ClaudeRequestIdentity.validDeviceID(replacement))
        check("replacement_persists_across_reopening", try reopened.loadDeviceID() == replacement &&
              reopened.loadOrCreateDeviceID() == replacement)
        let replacementMode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        check("replacement_keeps_private_permissions", replacementMode?.intValue == 0o600)
        check("replacement_leaves_no_temporary_files", try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path) == ["installation.json"])

        let concurrentStore = FileInstallationIdentityStore(directoryURL: root.appendingPathComponent("concurrent"))
        let results = InstallationIdentityCheckResults()
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do { results.append(try concurrentStore.loadOrCreateDeviceID()) }
            catch { results.append(nil) }
        }
        let values = results.values()
        check("concurrent_first_use_publishes_one_complete_identity", values.count == 12 && values.allSatisfy { $0 != nil } && Set(values.compactMap { $0 }).count == 1)

        let corrupt = Data("{broken identity".utf8)
        try corrupt.write(to: store.fileURL)
        do { _ = try store.loadOrCreateDeviceID(); check("corrupt_identity_fails_closed", false) }
        catch { check("corrupt_identity_fails_closed", try Data(contentsOf: store.fileURL) == corrupt) }
        do { _ = try store.replaceDeviceID(); check("corrupt_identity_replacement_fails_closed", false) }
        catch { check("corrupt_identity_replacement_fails_closed", try Data(contentsOf: store.fileURL) == corrupt) }
        let future = try JSONSerialization.data(withJSONObject: ["schemaVersion": 99, "deviceID": deviceID])
        try future.write(to: store.fileURL)
        do { _ = try store.loadOrCreateDeviceID(); check("future_identity_preserved", false) }
        catch { check("future_identity_preserved", try Data(contentsOf: store.fileURL) == future) }
        do { _ = try store.replaceDeviceID(); check("future_identity_replacement_preserves_data", false) }
        catch { check("future_identity_replacement_preserves_data", try Data(contentsOf: store.fileURL) == future) }

        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: second.fileURL)
        let secondData = try Data(contentsOf: second.fileURL)
        do { _ = try store.loadOrCreateDeviceID(); check("symlink_identity_rejected", false) }
        catch { check("symlink_identity_rejected", try Data(contentsOf: second.fileURL) == secondData) }
        do { _ = try store.replaceDeviceID(); check("symlink_identity_replacement_rejected", false) }
        catch {
            check("symlink_identity_replacement_rejected", try Data(contentsOf: second.fileURL) == secondData &&
                  FileManager.default.destinationOfSymbolicLink(atPath: store.fileURL.path) == second.fileURL.path)
        }

        let linkedDirectory = FileInstallationIdentityStore(directoryURL: root.appendingPathComponent("linked-directory"))
        try FileManager.default.createSymbolicLink(at: linkedDirectory.directoryURL, withDestinationURL: second.directoryURL)
        do { _ = try linkedDirectory.replaceDeviceID(); check("symlink_directory_replacement_rejected", false) }
        catch {
            check("symlink_directory_replacement_rejected", try Data(contentsOf: second.fileURL) == secondData &&
                  FileManager.default.destinationOfSymbolicLink(atPath: linkedDirectory.directoryURL.path) == second.directoryURL.path)
        }

        let blockedDirectory = root.appendingPathComponent("not-a-directory")
        let blocker = Data("synthetic directory blocker".utf8)
        try blocker.write(to: blockedDirectory)
        let blocked = FileInstallationIdentityStore(directoryURL: blockedDirectory.appendingPathComponent("Identity"))
        do { _ = try blocked.replaceDeviceID(); check("replacement_reports_io_failure", false) }
        catch { check("replacement_reports_io_failure", try Data(contentsOf: blockedDirectory) == blocker) }

        if geteuid() != 0 {
            let readOnly = FileInstallationIdentityStore(directoryURL: root.appendingPathComponent("read-only"))
            _ = try readOnly.loadOrCreateDeviceID()
            let before = try Data(contentsOf: readOnly.fileURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.directoryURL.path)
            var failed = false
            do { _ = try readOnly.replaceDeviceID() }
            catch InstallationIdentityFailure.replacementFailed { failed = true }
            catch { check("replacement_reports_write_failure_type", false) }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.directoryURL.path)
            check("replacement_reports_write_failure", try failed && Data(contentsOf: readOnly.fileURL) == before)
        }

        let sessionID = UUID()
        let identity = ClaudeRequestIdentity(device_id: deviceID, session_id: sessionID.uuidString)
        try identity.validate()
        var request = ChatRequest(request_id: UUID().uuidString, model: "sonnet", messages: [.init(role: "user", text: "synthetic")],
            provider: .claudeSubscription, subscriptionToken: "sk-ant-oat01-installation-identity-fixture", identity: identity,
            conversationSessionID: sessionID)
        try request.validate()
        let input = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        check("only_explicit_identity_envelope_is_encoded", input["conversationSessionID"] == nil &&
              (input["identity"] as? [String: String]) == ["device_id": deviceID, "session_id": sessionID.uuidString])
        request.identity = .init(device_id: "not-a-device", session_id: sessionID.uuidString)
        do { try request.validate(); check("invalid_identity_rejected", false) }
        catch { check("invalid_identity_rejected", true) }
    } catch { check("fixture_completed", false) }
    return checks
}

private final class InstallationIdentityCheckResults: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String?] = []
    func append(_ value: String?) { lock.lock(); defer { lock.unlock() }; recorded.append(value) }
    func values() -> [String?] { lock.lock(); defer { lock.unlock() }; return recorded }
}
