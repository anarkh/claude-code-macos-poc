import Foundation

/// Simulates a successful replacement whose verification fails after the write.
private final class UnconfirmedIdentityReplacementStore: InstallationIdentityManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var current = String(repeating: "a", count: 64)
    let replacement = String(repeating: "b", count: 64)

    func loadDeviceID() throws -> String? { lock.withLock { current } }
    func loadOrCreateDeviceID() throws -> String { lock.withLock { current } }
    func replaceDeviceID() throws -> String {
        lock.withLock { current = replacement }
        throw InstallationIdentityFailure.replacementFailed
    }
}

/// Settings checks use private temporary identity files and a synthetic store only.
@MainActor
func deviceIdentitySettingsChecks() -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { checks.append(("device_identity_settings_" + name, passed)) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("device-identity-settings-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let store = FileInstallationIdentityStore(directoryURL: root.appendingPathComponent("identity"))
        let model = DeviceIdentitySettingsModel(store: store)
        model.refresh()
        check("opening_settings_does_not_create_identity", model.deviceID == nil && model.error == nil &&
              !FileManager.default.fileExists(atPath: store.directoryURL.path))
        model.replaceDeviceID(isAllowed: false)
        check("busy_missing_identity_does_not_create", model.deviceID == nil && model.status == nil && model.error != nil &&
              !FileManager.default.fileExists(atPath: store.directoryURL.path))

        let original = try store.loadOrCreateDeviceID()
        let originalData = try Data(contentsOf: store.fileURL)
        model.refresh()
        check("refresh_reads_without_rewriting", try model.deviceID == original && model.error == nil &&
              Data(contentsOf: store.fileURL) == originalData)
        model.replaceDeviceID(isAllowed: true)
        let reopened = FileInstallationIdentityStore(directoryURL: store.directoryURL)
        let replacement = try reopened.loadDeviceID()
        check("replacement_displays_persisted_identity", replacement != nil && replacement != original &&
              model.deviceID == replacement && model.error == nil && model.status != nil)
        let replacementData = try Data(contentsOf: store.fileURL)
        model.replaceDeviceID(isAllowed: false)
        check("busy_existing_identity_is_not_replaced", try model.deviceID == replacement && model.status == nil &&
              model.error != nil && Data(contentsOf: store.fileURL) == replacementData)

        let corrupt = Data("{invalid-settings-identity".utf8)
        try corrupt.write(to: store.fileURL)
        model.refresh()
        check("read_failure_hides_stale_identity_and_preserves_data", try model.deviceID == nil && model.error != nil &&
              Data(contentsOf: store.fileURL) == corrupt)
        try replacementData.write(to: store.fileURL)
        model.refresh()
        check("refresh_recovers_after_read_failure", model.deviceID == replacement && model.error == nil)
        try corrupt.write(to: store.fileURL)
        model.replaceDeviceID(isAllowed: true)
        check("replacement_failure_hides_stale_identity_and_preserves_data", try model.deviceID == nil &&
              model.status == nil && model.error != nil && Data(contentsOf: store.fileURL) == corrupt)
    } catch { check("temporary_identity_fixture", false) }
    if FileManager.default.fileExists(atPath: root.path) {
        do {
            try FileManager.default.removeItem(at: root)
            check("temporary_state_cleanup", true)
        } catch { check("temporary_state_cleanup", false) }
    }

    let unconfirmed = UnconfirmedIdentityReplacementStore()
    let model = DeviceIdentitySettingsModel(store: unconfirmed)
    model.refresh()
    let original = model.deviceID
    model.replaceDeviceID(isAllowed: true)
    check("post_write_failure_never_displays_old_identity", original != nil && original != unconfirmed.replacement &&
          model.deviceID == nil && model.status == nil && model.error == InstallationIdentityFailure.replacementFailed.errorDescription)
    model.refresh()
    check("refresh_recovers_actual_identity_after_unconfirmed_write", model.deviceID == unconfirmed.replacement && model.error == nil)
    return checks
}
