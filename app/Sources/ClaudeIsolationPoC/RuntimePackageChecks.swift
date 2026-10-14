import CryptoKit
import Darwin
import Foundation

/// These packages are signed with a fresh, fixture-only key and contain inert
/// scripts plus a tiny image. No fixture artifact is ever launched.
private struct RuntimePackageFixture {
    let root: URL
    let bundleContents: URL
    let storageRoot: URL
    let signingKey = Curve25519.Signing.PrivateKey()

    init(root: URL) throws {
        self.root = root
        bundleContents = root.appendingPathComponent("Fixture.app/Contents")
        storageRoot = root.appendingPathComponent("private-store")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: bundleContents, withIntermediateDirectories: true)
        let manifest = try Self.writeContents(at: bundleContents, version: "1.0.0")
        let resources = bundleContents.appendingPathComponent("Resources")
        try Self.encode(manifest).write(to: resources.appendingPathComponent("BundledRuntimeManifest.json"))
        let key = signingKey.publicKey.rawRepresentation
        let trust = RuntimePackageTrust(schema: RuntimePackageTrust.schemaValue,
                                        publicKeys: [Self.digest(key): key.base64EncodedString()])
        try Self.encode(trust).write(to: resources.appendingPathComponent("RuntimeTrust.json"))
        let info: [String: Any] = ["CFBundleIdentifier": "com.claude-isolation-poc.runtime-package-fixture",
                                   "CFBundleShortVersionString": "0.12.0", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundleContents.appendingPathComponent("Info.plist"))
    }

    func store() -> RuntimePackageStore { .init(bundleContents: bundleContents, storageRoot: storageRoot) }

    func updateBundledRuntime(version: String, appVersion: String) throws {
        let manifest = try Self.writeContents(at: bundleContents, version: version)
        try Self.encode(manifest).write(to: bundleContents.appendingPathComponent("Resources/BundledRuntimeManifest.json"))
        let infoURL = bundleContents.appendingPathComponent("Info.plist")
        var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
        info["CFBundleShortVersionString"] = appVersion
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
    }

    func package(version: String = "1.1.0", signer: Curve25519.Signing.PrivateKey? = nil) throws -> URL {
        let package = root.appendingPathComponent("fixture-\(UUID().uuidString).clauderuntime")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let contents = package.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
        let manifest = try Self.writeContents(at: contents, version: version)
        try sign(package, manifestBytes: Self.encode(manifest), signer: signer)
        return package
    }

    func sign(_ package: URL, manifestBytes: Data, signer: Curve25519.Signing.PrivateKey? = nil) throws {
        let signer = signer ?? signingKey
        let signature = RuntimePackageSignature(schema: RuntimePackageSignature.schemaValue,
                                                keyID: Self.digest(signer.publicKey.rawRepresentation),
                                                signature: try signer.signature(for: manifestBytes).base64EncodedString())
        try manifestBytes.write(to: package.appendingPathComponent("manifest.json"))
        try Self.encode(signature).write(to: package.appendingPathComponent("signature.json"))
    }

    func mutateManifest(_ package: URL, resign: Bool = true, _ mutation: (inout [String: Any]) throws -> Void) throws {
        let manifestURL = package.appendingPathComponent("manifest.json")
        guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] else {
            throw RuntimePackageFailure.invalidPackage
        }
        try mutation(&object)
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if resign { try sign(package, manifestBytes: bytes) }
        else { try bytes.write(to: manifestURL) }
    }

    func pendingContents(_ info: RuntimePackageInfo) -> URL {
        storageRoot.appendingPathComponent("versions/\(info.id)/Contents")
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeContents(at contents: URL, version: String) throws -> RuntimePackageManifest {
        let manager = FileManager.default
        var bytes: [String: Data] = [:]
        for path in RuntimePackageManifest.requiredPaths {
            bytes[path] = Data("fixture-only \(version) \(path)\n".utf8)
        }
        let imagePrefix = "Resources/Runtime/host/text-runtime/images/"
        let disk = bytes[RuntimePackageManifest.diskPath]!
        let base: [String: Any] = ["schema": "claude-text-vm-base/v1", "prepared": true,
                                  "no_user_data": true, "network_devices": 0, "directory_shares": 0,
                                  "node_version": "26.7.0", "sdk_version": "0.3.295", "cli_version": "2.1.295",
                                  "disk_bytes": disk.count, "disk_sha256": digest(disk),
                                  "kernel_sha256": digest(bytes[imagePrefix + "kernel"]!),
                                  "initrd_sha256": digest(bytes[imagePrefix + "initrd"]!)]
        bytes[imagePrefix + "base.json"] = try JSONSerialization.data(withJSONObject: base, options: [.sortedKeys])
        let config: [String: Any] = ["schema": "claude-vm-runtime/v1", "image_dir": "images",
                                    "runner": "../../../../Helpers/vm-text-runtime",
                                    "guest_runtime_dir": "../../guest/text-runtime", "python": "/usr/bin/python3"]
        bytes["Resources/Runtime/host/text-runtime/runtime-config.json"] =
            try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        bytes["Resources/Runtime/sdk/package.json"] = try JSONSerialization.data(withJSONObject:
            ["name": "runtime-package-offline-fixture", "version": version,
             "dependencies": ["@anthropic-ai/claude-agent-sdk": "0.3.295"]], options: [.sortedKeys])
        var files: [RuntimePackageFile] = []
        for path in bytes.keys.sorted() {
            let file = contents.appendingPathComponent(path)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload = bytes[path]!
            try payload.write(to: file)
            let executable = path == "Helpers/vm-text-runtime" || path.hasSuffix(".sh")
            try manager.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: file.path)
            files.append(.init(path: path, size: Int64(payload.count), sha256: digest(payload), executable: executable))
        }
        return .init(schema: RuntimePackageManifest.schemaValue, version: version,
                     cliVersion: "2.1.295", sdkVersion: "0.3.295", nodeVersion: "26.7.0",
                     hostProtocol: 1, platform: "macOS-arm64", minimumOSVersion: "14.0.0",
                     minimumAppVersion: "0.12.0", maximumAppVersionExclusive: "0.13.0", files: files)
    }
}

private final class RuntimePackageProgressFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    private var changed = false
    private var mutationFailed = false
    private let mutation: (@Sendable () throws -> Void)?
    init(mutation: (@Sendable () throws -> Void)? = nil) { self.mutation = mutation }
    func receive(_ value: Double) {
        lock.lock()
        values.append(value)
        let shouldMutate = value >= 0.45 && !changed
        if shouldMutate { changed = true }
        lock.unlock()
        if shouldMutate, let mutation {
            do { try mutation() }
            catch { lock.lock(); mutationFailed = true; lock.unlock() }
        }
    }
    var cancellationRequested: Bool { lock.lock(); defer { lock.unlock() }; return changed }
    var mutationSucceeded: Bool { lock.lock(); defer { lock.unlock() }; return changed && !mutationFailed }
    var completedWithValidProgress: Bool {
        lock.lock(); defer { lock.unlock() }
        return values.last == 1 && values.allSatisfy { $0 >= 0 && $0 <= 1 && $0.isFinite } &&
            zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }
    }
}

private func runtimePackageStorageNames(_ root: URL) throws -> Set<String> {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    guard let enumeration = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
        throw RuntimePackageFailure.persistenceFailed
    }
    var paths = Set<String>()
    while let url = enumeration.nextObject() as? URL {
        paths.insert(String(url.path.dropFirst(root.path.count + 1)))
    }
    return paths
}

private func runtimePackageRemoveFixture(_ root: URL) throws {
    let manager = FileManager.default
    guard manager.fileExists(atPath: root.path) else { return }
    func writable(_ directory: URL) throws {
        guard chmod(directory.path, 0o700) == 0 else { throw RuntimePackageFailure.persistenceFailed }
        for entry in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            var metadata = stat()
            guard lstat(entry.path, &metadata) == 0 else { throw RuntimePackageFailure.persistenceFailed }
            if (metadata.st_mode & S_IFMT) == S_IFDIR { try writable(entry) }
        }
    }
    try writable(root)
    try manager.removeItem(at: root)
}

#if !RUNTIME_PACKAGE_CORE_ONLY
/// Delegates to the production importer, holding its verified-copy boundary
/// until the model's real cancellation controller requests termination.
private final class RuntimePackageHeldImportFixture: RuntimePackageManaging, @unchecked Sendable {
    private let base: RuntimePackageStore
    private let condition = NSCondition()
    private var reached = false
    private var expired = false
    init(_ base: RuntimePackageStore) { self.base = base }
    var copyBoundaryReached: Bool { condition.lock(); defer { condition.unlock() }; return reached }
    var gateExpired: Bool { condition.lock(); defer { condition.unlock() }; return expired }
    func snapshot() throws -> RuntimePackageSnapshot { try base.snapshot() }
    func requestRollback() throws { try base.requestRollback() }
    func activatePending() throws { try base.activatePending() }
    func cancelPending() throws { try base.cancelPending() }
    func resolvedRuntimeRoot() throws -> URL { try base.resolvedRuntimeRoot() }
    func importPackage(at url: URL, shouldCancel: @Sendable () -> Bool,
                       progress: @Sendable (Double) -> Void) throws -> RuntimePackageInfo {
        try base.importPackage(at: url, shouldCancel: { shouldCancel() || self.gateExpired }, progress: { value in
            self.condition.lock()
            if value >= 0.45 && !self.reached {
                self.reached = true
                let deadline = Date(timeIntervalSinceNow: 2)
                while !shouldCancel() {
                    if Date() >= deadline { self.expired = true; break }
                    _ = self.condition.wait(until: Date(timeIntervalSinceNow: 0.01))
                }
            }
            self.condition.unlock()
            progress(value)
        })
    }
}

@MainActor
private func runtimePackageAwait(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        do { try await Task.sleep(for: .milliseconds(10)) }
        catch { return false }
    }
    return false
}

@MainActor
private func runtimePackageModelChecks(_ makeFixture: () throws -> RuntimePackageFixture) async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    func check(_ name: String, _ passed: Bool) { checks["runtime_package_model_" + name] = passed }
    do {
        let fixture = try makeFixture(), store = fixture.store(), registry = OwnedProcessRegistry()
        let bundled = try store.snapshot().bundled
        let pending = try store.importPackage(at: fixture.package(), shouldCancel: { false }, progress: { _ in })
        let worker = OwnedProcessController()
        try worker.registerWork(in: registry)
        let model = RuntimeVersionViewModel(store: store, registry: registry)
        check("active_worker_preserves_pending", model.snapshot?.current == bundled && model.snapshot?.pending == pending && registry.activeCount == 1)
        check("active_worker_keeps_bundled_launch_root", try store.resolvedRuntimeRoot() == fixture.bundleContents)
        worker.finish(); model.refresh()
        check("idle_refresh_activates_validated_package", model.snapshot?.current == pending && model.snapshot?.previous == bundled && model.snapshot?.pending == nil)
        registry.beginLoginReset(); model.requestRollback()
        check("login_reset_blocks_pending_rollback_activation", model.snapshot?.current == pending && model.snapshot?.pending == bundled)
        registry.endLoginReset(); model.refresh()
        check("post_reset_idle_activates_rollback", model.snapshot?.current == bundled && model.snapshot?.pending == nil)
        model.beginTermination()
    } catch { check("worker_and_reset_gate_fixture", false) }
    do {
        let fixture = try makeFixture(), store = fixture.store(), registry = OwnedProcessRegistry()
        let bundled = try store.snapshot().bundled
        let pending = try store.importPackage(at: fixture.package(), shouldCancel: { false }, progress: { _ in })
        var applicationIdle = false
        let model = RuntimeVersionViewModel(store: store, registry: registry, isApplicationIdle: { applicationIdle })
        check("ui_task_gap_does_not_switch_runtime", registry.activeCount == 0 && model.snapshot?.current == bundled && model.snapshot?.pending == pending)
        applicationIdle = true
        registry.beginTermination(); model.refresh()
        check("registry_termination_blocks_switch", model.snapshot?.current == bundled && model.snapshot?.pending == pending)
        registry.endTermination(); model.beginTermination(); model.refresh()
        check("model_termination_blocks_switch", model.snapshot?.current == bundled && model.snapshot?.pending == pending && !model.canImport)
        model.endTermination()
        check("failed_quit_resume_applies_pending_when_idle", model.snapshot?.current == pending && model.snapshot?.pending == nil)
        model.beginTermination()
    } catch { check("application_idle_and_termination_gate_fixture", false) }
    do {
        let fixture = try makeFixture(), store = fixture.store(), registry = OwnedProcessRegistry()
        try store.cancelPending()
        let baseline = try store.snapshot(), inventory = try runtimePackageStorageNames(fixture.storageRoot)
        let source = try fixture.package(), heldStore = RuntimePackageHeldImportFixture(store)
        let model = RuntimeVersionViewModel(store: heldStore, registry: registry)
        let importing = Task { await model.importPackage(at: source) }
        check("import_reaches_real_verified_copy_boundary", await runtimePackageAwait { heldStore.copyBoundaryReached && model.isBusy && registry.activeCount == 1 })
        registry.beginTermination(); model.beginTermination()
        await importing.value
        check("quit_cancels_import_and_waits_for_cleanup", !heldStore.gateExpired && model.isTerminationWorkSettled && !model.isBusy && registry.activeCount == 0)
        check("quit_does_not_select_or_publish_pending_runtime", try store.snapshot() == baseline && model.snapshot?.current == baseline.current && model.snapshot?.pending == nil)
        check("quit_removes_only_own_partial_install", try runtimePackageStorageNames(fixture.storageRoot) == inventory)
        check("quit_retains_source_package", FileManager.default.fileExists(atPath: source.path))
        check("quit_keeps_import_admission_closed", !model.canImport && model.error != nil)
        registry.endTermination()
    } catch { check("inflight_import_termination_fixture", false) }
    return checks
}
#endif

@MainActor
func runtimePackageChecks() async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    func check(_ name: String, _ passed: Bool) { checks["runtime_package_" + name] = passed }
    let manager = FileManager.default
    guard let physicalTemporaryDirectory = realpath(manager.temporaryDirectory.path, nil) else {
        return ["runtime_package_physical_temporary_directory": false]
    }
    let temporaryDirectory = URL(fileURLWithPath: String(cString: physicalTemporaryDirectory))
    free(physicalTemporaryDirectory)
    let root = temporaryDirectory.appendingPathComponent("runtime-package-checks-" + UUID().uuidString)
    do { try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    catch { return ["runtime_package_fixture_setup": false] }
    var nextCase = 0
    func fixture() throws -> RuntimePackageFixture {
        nextCase += 1
        return try .init(root: root.appendingPathComponent("case-\(nextCase)"))
    }
    func expectFailure(_ name: String, _ expected: [RuntimePackageFailure], _ operation: () throws -> Void) {
        do { try operation(); check(name, false) }
        catch let failure as RuntimePackageFailure { check(name, expected.contains(failure) && !failure.message.isEmpty) }
        catch { check(name, false) }
    }

    do {
        let fixture = try fixture(), store = fixture.store()
        let bundled = try store.snapshot()
        check("initial_selection_is_bundled", bundled.current == bundled.bundled && bundled.previous == nil && bundled.pending == nil)
        check("initial_runtime_root_is_bundle_contents", try store.resolvedRuntimeRoot() == fixture.bundleContents)
        expectFailure("rollback_without_previous_is_explicit", [.noPrevious]) { try store.requestRollback() }
        expectFailure("activate_without_pending_is_explicit", [.noPending]) { try store.activatePending() }
        let source = try fixture.package(), progress = RuntimePackageProgressFixture()
        let imported = try store.importPackage(at: source, shouldCancel: { false }, progress: { progress.receive($0) })
        let staged = try store.snapshot()
        check("signed_full_package_is_pending", staged.pending == imported && imported.version == "1.1.0" &&
              imported.cliVersion == "2.1.295" && imported.sdkVersion == "0.3.295" && imported.nodeVersion == "26.7.0")
        let pendingRoot = try store.resolvedRuntimeRoot()
        check("import_does_not_switch_current", staged.current == bundled.current && staged.previous == nil &&
              pendingRoot == fixture.bundleContents)
        check("import_progress_completes_monotonically", progress.completedWithValidProgress)
        check("pending_and_current_survive_restart", try fixture.store().snapshot() == staged)
        let storedManifest = fixture.pendingContents(imported).deletingLastPathComponent().appendingPathComponent("manifest.json")
        check("stored_manifest_retains_signed_bytes", try Data(contentsOf: storedManifest) == Data(contentsOf: source.appendingPathComponent("manifest.json")))
        try store.activatePending()
        let activated = try store.snapshot()
        check("activation_sets_current_and_previous", activated.current == imported && activated.previous == bundled.bundled && activated.pending == nil)
        check("activated_root_uses_private_complete_contents", try store.resolvedRuntimeRoot() == fixture.pendingContents(imported))
        check("activation_survives_restart", try fixture.store().snapshot() == activated)
        #if !RUNTIME_PACKAGE_CORE_ONLY
        let configuration = AppConfiguration(projectRoot: "/fixture-source-must-not-be-selected", nodeExecutable: "/fixture-node-not-executed", runtimePackages: store)
        let selectedConfiguration = try configuration.resolvingClaudeRuntime()
        check("configuration_resolves_imported_runtime_without_execution_fixture_bypass",
              selectedConfiguration.projectRoot == fixture.pendingContents(imported).appendingPathComponent("Resources/Runtime").path &&
              selectedConfiguration.nodeExecutable == configuration.nodeExecutable)
        #endif
        try manager.removeItem(at: source)
        check("source_removal_does_not_break_import", try fixture.store().resolvedRuntimeRoot() == fixture.pendingContents(imported))
        try store.requestRollback()
        let rollbackPending = try store.snapshot()
        check("rollback_request_preserves_current_until_activation", rollbackPending.current == imported && rollbackPending.pending == bundled.bundled)
        check("rollback_pending_survives_restart", try fixture.store().snapshot() == rollbackPending)
        try store.activatePending()
        let rolledBack = try fixture.store().snapshot()
        check("rollback_restores_bundle_and_records_previous", rolledBack.current == bundled.bundled && rolledBack.previous == imported && rolledBack.pending == nil)
        check("rollback_resolves_bundle_after_restart", try fixture.store().resolvedRuntimeRoot() == fixture.bundleContents)
        #if !RUNTIME_PACKAGE_CORE_ONLY
        check("configuration_resolves_rollback_from_same_injected_store", try configuration.resolvingClaudeRuntime().projectRoot == fixture.bundleContents.appendingPathComponent("Resources/Runtime").path)
        #endif
        let next = try store.importPackage(at: fixture.package(version: "1.2.0"), shouldCancel: { false }, progress: { _ in })
        check("second_import_is_pending", try store.snapshot().pending == next)
        try store.cancelPending()
        let cancelled = try fixture.store().snapshot()
        check("cancel_pending_keeps_current_and_rollback", cancelled.current == rolledBack.current && cancelled.previous == rolledBack.previous && cancelled.pending == nil)
        check("cancel_pending_keeps_runtime_root", try store.resolvedRuntimeRoot() == fixture.bundleContents)
    } catch { check("import_activation_rollback_fixture", false) }

    do {
        let fixture = try fixture(), store = fixture.store()
        let imported = try store.importPackage(at: fixture.package(), shouldCancel: { false }, progress: { _ in })
        try store.activatePending()
        let stateURL = fixture.storageRoot.appendingPathComponent("state.json"), stateBefore = try Data(contentsOf: stateURL)
        try fixture.updateBundledRuntime(version: "1.0.1", appVersion: "0.12.1")
        let upgradedStore = fixture.store(), snapshot = try upgradedStore.snapshot()
        check("app_patch_keeps_imported_current", snapshot.current == imported && snapshot.bundled.version == "1.0.1")
        check("app_patch_previous_resolves_current_bundle_baseline", snapshot.previous == snapshot.bundled && snapshot.previous?.id == "bundled")
        check("app_patch_keeps_durable_selection_bytes", try Data(contentsOf: stateURL) == stateBefore)
        try upgradedStore.requestRollback(); try upgradedStore.activatePending()
        check("app_patch_rollback_uses_new_bundle_baseline", try upgradedStore.snapshot().current == snapshot.bundled && upgradedStore.resolvedRuntimeRoot() == fixture.bundleContents)
    } catch { check("app_patch_compatibility_fixture", false) }

    // Each rejection starts with an imported active version. A failed import
    // must preserve both the selected version and the exact durable state.
    func rejectedImport(_ name: String, expected: [RuntimePackageFailure],
                        mutate: (RuntimePackageFixture, URL) throws -> Void) {
        do {
            let fixture = try fixture(), store = fixture.store()
            let active = try store.importPackage(at: fixture.package(), shouldCancel: { false }, progress: { _ in })
            try store.activatePending()
            let before = try store.snapshot(), stateURL = fixture.storageRoot.appendingPathComponent("state.json")
            let stateBytes = try Data(contentsOf: stateURL), inventory = try runtimePackageStorageNames(fixture.storageRoot)
            let package = try fixture.package(version: "1.2.0")
            try mutate(fixture, package)
            expectFailure(name + "_rejected", expected) {
                _ = try store.importPackage(at: package, shouldCancel: { false }, progress: { _ in })
            }
            check(name + "_selection_and_state_preserved", try store.snapshot() == before && Data(contentsOf: stateURL) == stateBytes)
            check(name + "_no_partial_install", try runtimePackageStorageNames(fixture.storageRoot) == inventory &&
                  store.resolvedRuntimeRoot() == fixture.pendingContents(active))
        } catch { check(name + "_fixture", false) }
    }
    rejectedImport("tampered_manifest", expected: [.integrityFailed]) { fixture, source in
        try fixture.mutateManifest(source, resign: false) { $0["version"] = "9.0.0" }
    }
    rejectedImport("tampered_signature", expected: [.integrityFailed]) { _, source in
        let signatureURL = source.appendingPathComponent("signature.json")
        var signature = try JSONSerialization.jsonObject(with: Data(contentsOf: signatureURL)) as! [String: Any]
        signature["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
        try JSONSerialization.data(withJSONObject: signature, options: [.sortedKeys]).write(to: signatureURL)
    }
    rejectedImport("untrusted_signer", expected: [.untrustedSigner]) { fixture, source in
        try fixture.sign(source, manifestBytes: Data(contentsOf: source.appendingPathComponent("manifest.json")),
                         signer: Curve25519.Signing.PrivateKey())
    }
    rejectedImport("tampered_payload", expected: [.integrityFailed]) { _, source in
        let file = source.appendingPathComponent("Contents/" + RuntimePackageManifest.diskPath)
        var bytes = try Data(contentsOf: file); bytes[0] ^= 1; try bytes.write(to: file)
    }
    rejectedImport("path_traversal", expected: [.invalidPackage]) { fixture, source in
        try fixture.mutateManifest(source) { object in
            var files = object["files"] as! [[String: Any]]
            files.append(["path": "Resources/Runtime/../../outside", "size": 0,
                          "sha256": RuntimePackageFixture.digest(Data()), "executable": false])
            object["files"] = files
        }
    }
    rejectedImport("absolute_path", expected: [.invalidPackage]) { fixture, source in
        try fixture.mutateManifest(source) { object in
            var files = object["files"] as! [[String: Any]]
            files[0]["path"] = "/tmp/fixture-outside"; object["files"] = files
        }
    }
    rejectedImport("duplicate_path", expected: [.invalidPackage]) { fixture, source in
        try fixture.mutateManifest(source) { object in
            var files = object["files"] as! [[String: Any]]; files.append(files[0]); object["files"] = files
        }
    }
    rejectedImport("file_symlink", expected: [.invalidPackage, .integrityFailed]) { fixture, source in
        let file = source.appendingPathComponent("Contents/Resources/Runtime/translation/stdio.mjs")
        let target = fixture.root.appendingPathComponent("external-fixture-preserve")
        try manager.moveItem(at: file, to: target)
        try manager.createSymbolicLink(at: file, withDestinationURL: target)
    }
    rejectedImport("ancestor_symlink", expected: [.invalidPackage, .integrityFailed]) { fixture, source in
        let directory = source.appendingPathComponent("Contents/Resources/Runtime/translation")
        let target = fixture.root.appendingPathComponent("external-directory-preserve")
        try manager.moveItem(at: directory, to: target)
        try manager.createSymbolicLink(at: directory, withDestinationURL: target)
    }
    rejectedImport("hard_link", expected: [.invalidPackage, .integrityFailed]) { fixture, source in
        let file = source.appendingPathComponent("Contents/Resources/Runtime/translation/stdio.mjs")
        try manager.linkItem(at: file, to: fixture.root.appendingPathComponent("extra-hard-link"))
    }
    rejectedImport("extra_payload", expected: [.invalidPackage, .integrityFailed]) { _, source in
        try Data("unlisted fixture payload".utf8).write(to: source.appendingPathComponent("Contents/Resources/Runtime/unlisted.mjs"))
    }
    rejectedImport("extra_package_metadata", expected: [.invalidPackage]) { _, source in
        try Data("unlisted root file".utf8).write(to: source.appendingPathComponent("README.txt"))
    }
    rejectedImport("missing_required_payload", expected: [.integrityFailed]) { _, source in
        try manager.removeItem(at: source.appendingPathComponent("Contents/Resources/Runtime/sdk/vm-text-chat.mjs"))
    }
    rejectedImport("protocol_incompatible", expected: [.invalidPackage, .incompatible]) { fixture, source in
        try fixture.mutateManifest(source) { $0["hostProtocol"] = 2 }
    }
    rejectedImport("app_version_incompatible", expected: [.incompatible]) { fixture, source in
        try fixture.mutateManifest(source) { $0["minimumAppVersion"] = "0.13.0"; $0["maximumAppVersionExclusive"] = "0.14.0" }
    }
    rejectedImport("base_receipt_not_clean", expected: [.invalidPackage]) { fixture, source in
        let baseURL = source.appendingPathComponent("Contents/Resources/Runtime/host/text-runtime/images/base.json")
        var base = try JSONSerialization.jsonObject(with: Data(contentsOf: baseURL)) as! [String: Any]
        base["no_user_data"] = false
        let changedBytes = try JSONSerialization.data(withJSONObject: base, options: [.sortedKeys])
        try changedBytes.write(to: baseURL)
        try fixture.mutateManifest(source) { object in
            var files = object["files"] as! [[String: Any]]
            let index = files.firstIndex { $0["path"] as? String == "Resources/Runtime/host/text-runtime/images/base.json" }!
            files[index]["size"] = changedBytes.count; files[index]["sha256"] = RuntimePackageFixture.digest(changedBytes)
            object["files"] = files
        }
    }

    for mode in ["cancel_after_verification", "copy_source_changed"] {
        do {
            let fixture = try fixture(), store = fixture.store()
            try store.cancelPending()
            let unrelatedStaging = fixture.storageRoot.appendingPathComponent(".staging-unrelated-fixture")
            try manager.createDirectory(at: unrelatedStaging, withIntermediateDirectories: false)
            let unrelatedMarker = unrelatedStaging.appendingPathComponent("preserve.txt")
            let unrelatedBytes = Data("unrelated fixture staging must remain".utf8)
            try unrelatedBytes.write(to: unrelatedMarker)
            let baseline = try store.snapshot(), source = try fixture.package()
            let inventory = try runtimePackageStorageNames(fixture.storageRoot)
            let payloadURL = source.appendingPathComponent("Contents/Resources/Runtime/translation/stdio.mjs")
            let mutation: (@Sendable () throws -> Void)?
            if mode == "copy_source_changed" {
                mutation = {
                    var bytes = try Data(contentsOf: payloadURL); bytes[0] ^= 1; try bytes.write(to: payloadURL)
                }
            } else { mutation = nil }
            let progress = RuntimePackageProgressFixture(mutation: mutation)
            let expected: RuntimePackageFailure = mode == "copy_source_changed" ? .integrityFailed : .cancelled
            expectFailure(mode + "_rejected", [expected]) {
                _ = try store.importPackage(at: source,
                    shouldCancel: { mode == "cancel_after_verification" && progress.cancellationRequested },
                    progress: { progress.receive($0) })
            }
            check(mode + "_hook_was_reached", progress.mutationSucceeded)
            check(mode + "_current_and_pending_preserved", try store.snapshot() == baseline)
            check(mode + "_owned_staging_removed", try runtimePackageStorageNames(fixture.storageRoot) == inventory)
            check(mode + "_unrelated_staging_retained", try Data(contentsOf: unrelatedMarker) == unrelatedBytes)
            check(mode + "_source_is_retained", manager.fileExists(atPath: source.path))
        } catch { check(mode + "_fixture", false) }
    }

    for corruption in ["state_json", "selected_manifest", "selected_payload"] {
        do {
            let fixture = try fixture(), store = fixture.store()
            let imported = try store.importPackage(at: fixture.package(), shouldCancel: { false }, progress: { _ in })
            try store.activatePending()
            let stateURL = fixture.storageRoot.appendingPathComponent("state.json")
            if corruption == "state_json" { try Data("{invalid-state".utf8).write(to: stateURL) }
            else {
                let file = corruption == "selected_manifest"
                    ? fixture.pendingContents(imported).deletingLastPathComponent().appendingPathComponent("manifest.json")
                    : fixture.pendingContents(imported).appendingPathComponent("Resources/Runtime/translation/stdio.mjs")
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                try Data("corrupt fixture selected runtime".utf8).write(to: file)
            }
            let stateBefore = try Data(contentsOf: stateURL), restarted = fixture.store()
            if corruption != "state_json" {
                let diagnostic = try restarted.snapshot()
                check(corruption + "_metadata_does_not_select_fallback", diagnostic.current.id == imported.id && diagnostic.current.id != diagnostic.bundled.id)
            } else {
                expectFailure(corruption + "_restart_rejected", [.invalidState, .invalidPackage, .integrityFailed]) { _ = try restarted.snapshot() }
            }
            expectFailure(corruption + "_launch_does_not_fallback", [.invalidState, .invalidPackage, .integrityFailed]) { _ = try restarted.resolvedRuntimeRoot() }
            #if !RUNTIME_PACKAGE_CORE_ONLY
            let configuration = AppConfiguration(projectRoot: "/fixture-source-must-not-be-selected", nodeExecutable: "/fixture-node-not-executed", runtimePackages: restarted)
            expectFailure(corruption + "_configuration_does_not_fallback", [.invalidState, .invalidPackage, .integrityFailed]) { _ = try configuration.resolvingClaudeRuntime() }
            #endif
            if corruption == "state_json" {
                expectFailure(corruption + "_rollback_does_not_overwrite", [.invalidState]) { try restarted.requestRollback() }
            }
            check(corruption + "_state_bytes_retained", try Data(contentsOf: stateURL) == stateBefore)
        } catch { check(corruption + "_fixture", false) }
    }

    #if !RUNTIME_PACKAGE_CORE_ONLY
    checks.merge(await runtimePackageModelChecks(fixture), uniquingKeysWith: { _, new in new })
    #endif

    do { try runtimePackageRemoveFixture(root); check("fixture_teardown", !manager.fileExists(atPath: root.path)) }
    catch { check("fixture_teardown", false) }
    return checks
}
