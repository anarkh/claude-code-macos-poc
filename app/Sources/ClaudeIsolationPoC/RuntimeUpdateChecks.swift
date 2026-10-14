import CryptoKit
import Darwin
import Foundation

/// All update fixtures are task-owned, inert packages signed by a fresh key.
/// They never select the user's catalog, signing key, source URL or credentials.
private struct RuntimeUpdateFixture {
    let root: URL
    let bundleContents: URL
    let storageRoot: URL
    let signingKey = Curve25519.Signing.PrivateKey()
    let feedURL = URL(string: "https://updates.fixture.example/stable/channel.json")!

    init(root: URL) throws {
        self.root = root
        bundleContents = root.appendingPathComponent("Fixture.app/Contents")
        storageRoot = root.appendingPathComponent("private-store")
        try RuntimePackageIO.createPrivateDirectory(root)
        try FileManager.default.createDirectory(at: bundleContents, withIntermediateDirectories: true)
        let manifest = try Self.writeContents(at: bundleContents, version: "1.0.0")
        try Self.encode(manifest).write(to: bundleContents.appendingPathComponent("Resources/BundledRuntimeManifest.json"))
        try Self.encode(trust).write(to: bundleContents.appendingPathComponent("Resources/RuntimeTrust.json"))
        let info: [String: Any] = ["CFBundleIdentifier": "com.claude-isolation-poc.runtime-update-fixture",
                                   "CFBundleShortVersionString": "0.12.1", "CFBundleVersion": "17"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundleContents.appendingPathComponent("Info.plist"))
    }

    var trust: RuntimePackageTrust {
        let key = signingKey.publicKey.rawRepresentation
        return .init(schema: RuntimePackageTrust.schemaValue,
                     publicKeys: [RuntimePackageIO.digest(key): key.base64EncodedString()])
    }

    func store() -> RuntimePackageStore { .init(bundleContents: bundleContents, storageRoot: storageRoot) }

    func package(version: String = "1.1.0") throws -> URL {
        let package = root.appendingPathComponent("fixture-\(UUID().uuidString).clauderuntime")
        try RuntimePackageIO.createPrivateDirectory(package)
        let contents = package.appendingPathComponent("Contents")
        try RuntimePackageIO.createPrivateDirectory(contents)
        let manifest = try Self.writeContents(at: contents, version: version)
        // Whitespace is intentional: the signed raw bytes must be preserved.
        var bytes = Data(" \n".utf8)
        bytes.append(try Self.encode(manifest)); bytes.append(10)
        try sign(package, manifestBytes: bytes)
        return package
    }

    func sign(_ package: URL, manifestBytes: Data, signer: Curve25519.Signing.PrivateKey? = nil) throws {
        let signer = signer ?? signingKey
        let signature = RuntimePackageSignature(schema: RuntimePackageSignature.schemaValue,
            keyID: RuntimePackageIO.digest(signer.publicKey.rawRepresentation),
            signature: try signer.signature(for: manifestBytes).base64EncodedString())
        try manifestBytes.write(to: package.appendingPathComponent("manifest.json"))
        try Self.encode(signature).write(to: package.appendingPathComponent("signature.json"))
    }

    func channel(_ package: URL, mutate: ((inout [String: Any]) throws -> Void)? = nil) throws -> Data {
        var object: [String: Any] = ["schema": "claude-runtime-channel/v1",
            "manifestBase64": try Data(contentsOf: package.appendingPathComponent("manifest.json")).base64EncodedString(),
            "signatureBase64": try Data(contentsOf: package.appendingPathComponent("signature.json")).base64EncodedString()]
        try mutate?(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func mutateManifest(_ package: URL, resign: Bool = true, _ mutation: (inout [String: Any]) throws -> Void) throws {
        let file = package.appendingPathComponent("manifest.json")
        guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
            throw RuntimePackageFailure.invalidPackage
        }
        try mutation(&object)
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if resign { try sign(package, manifestBytes: bytes) }
        else { try bytes.write(to: file) }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func writeContents(at contents: URL, version: String) throws -> RuntimePackageManifest {
        var bytes = Dictionary(uniqueKeysWithValues: RuntimePackageManifest.requiredPaths.map {
            ($0, Data("inert update fixture \(version) \($0)\n".utf8))
        })
        let prefix = "Resources/Runtime/host/text-runtime/images/"
        let disk = bytes[RuntimePackageManifest.diskPath]!
        bytes[prefix + "base.json"] = try JSONSerialization.data(withJSONObject: [
            "schema": "claude-text-vm-base/v1", "prepared": true, "no_user_data": true,
            "network_devices": 0, "directory_shares": 0, "node_version": "26.7.0",
            "sdk_version": "0.3.295", "cli_version": "2.1.295", "disk_bytes": disk.count,
            "disk_sha256": RuntimePackageIO.digest(disk),
            "kernel_sha256": RuntimePackageIO.digest(bytes[prefix + "kernel"]!),
            "initrd_sha256": RuntimePackageIO.digest(bytes[prefix + "initrd"]!)], options: [.sortedKeys])
        bytes["Resources/Runtime/host/text-runtime/runtime-config.json"] = try JSONSerialization.data(withJSONObject: [
            "schema": "claude-vm-runtime/v1", "image_dir": "images",
            "runner": "../../../../Helpers/vm-text-runtime", "guest_runtime_dir": "../../guest/text-runtime",
            "python": "/usr/bin/python3"], options: [.sortedKeys])
        bytes["Resources/Runtime/sdk/package.json"] = try JSONSerialization.data(withJSONObject: [
            "name": "runtime-update-fixture", "version": version,
            "dependencies": ["@anthropic-ai/claude-agent-sdk": "0.3.295"]], options: [.sortedKeys])
        var files: [RuntimePackageFile] = []
        for path in bytes.keys.sorted() {
            let file = contents.appendingPathComponent(path), payload = bytes[path]!
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: file)
            let executable = path == "Helpers/vm-text-runtime" || path.hasSuffix(".sh")
            guard chmod(file.path, executable ? 0o700 : 0o600) == 0 else { throw RuntimePackageFailure.persistenceFailed }
            files.append(.init(path: path, size: Int64(payload.count), sha256: RuntimePackageIO.digest(payload), executable: executable))
        }
        return .init(schema: RuntimePackageManifest.schemaValue, version: version, cliVersion: "2.1.295",
            sdkVersion: "0.3.295", nodeVersion: "26.7.0", hostProtocol: 1, platform: "macOS-arm64",
            minimumOSVersion: "14.0.0", minimumAppVersion: "0.12.0", maximumAppVersionExclusive: "0.13.0", files: files)
    }
}

private final class RuntimeUpdateHeldFixtureService: RuntimeUpdating, @unchecked Sendable {
    private let fixture: RuntimeUpdateFixture
    private let package: URL
    private let condition = NSCondition()
    private var heldCheck = false
    private var heldDownload = false
    private var checkReached = false
    private var downloadReached = false
    private var deadlineExpired = false
    private var checks = 0
    private var downloads = 0
    private var nextFailure: RuntimeUpdateFailure?

    init(fixture: RuntimeUpdateFixture, package: URL) { self.fixture = fixture; self.package = package }
    func hold(check: Bool = false, download: Bool = false) {
        condition.lock(); heldCheck = check; heldDownload = download; condition.broadcast(); condition.unlock()
    }
    func failNextDownload(_ failure: RuntimeUpdateFailure) {
        condition.lock(); nextFailure = failure; condition.unlock()
    }
    var reachedCheck: Bool { condition.lock(); defer { condition.unlock() }; return checkReached }
    var reachedDownload: Bool { condition.lock(); defer { condition.unlock() }; return downloadReached }
    var didExpire: Bool { condition.lock(); defer { condition.unlock() }; return deadlineExpired }
    var checkCount: Int { condition.lock(); defer { condition.unlock() }; return checks }
    var downloadCount: Int { condition.lock(); defer { condition.unlock() }; return downloads }

    private func wait(check: Bool, controller: OwnedProcessController) throws {
        condition.lock(); defer { condition.unlock() }
        if check { checks += 1; checkReached = true }
        else { downloads += 1; downloadReached = true }
        let deadline = Date(timeIntervalSinceNow: 3)
        while check ? heldCheck : heldDownload {
            if controller.isCancelled { throw RuntimeUpdateFailure.cancelled }
            if Date() >= deadline { deadlineExpired = true; throw RuntimeUpdateFailure.timeout }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01))
        }
        if controller.isCancelled { throw RuntimeUpdateFailure.cancelled }
    }

    func check(feedURL: URL, current: RuntimePackageInfo, controller: OwnedProcessController) throws -> RuntimeUpdateRelease? {
        try wait(check: true, controller: controller)
        return try StdioRuntimeUpdateService.checkChannel(fixture.channel(package), feedURL: feedURL,
            current: current, trust: fixture.trust, appVersion: "0.12.1")
    }

    func prepareAndImport(_ release: RuntimeUpdateRelease, store: any RuntimePackageManaging,
                          controller: OwnedProcessController,
                          progress: @Sendable (Double, String) -> Void) throws -> RuntimePackageInfo {
        progress(0.25, "正在下载测试运行包…")
        try wait(check: false, controller: controller)
        condition.lock(); let failure = nextFailure; nextFailure = nil; condition.unlock()
        if let failure { throw failure }
        return try store.importPackage(at: package, shouldCancel: { controller.isCancelled },
                                       progress: { progress($0, "正在校验测试运行包…") })
    }
}

@MainActor
private func runtimeUpdateAwait(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<150 {
        if predicate() { return true }
        do { try await Task.sleep(for: .milliseconds(10)) }
        catch { return false }
    }
    return false
}

@MainActor
func runtimeUpdateChecks() async -> [String: Bool] {
    var results: [String: Bool] = [:]
    func check(_ name: String, _ value: Bool) { results["runtime_update_" + name] = value }
    func reject(_ name: String, expected: RuntimeUpdateFailure? = nil, _ operation: () throws -> Void) {
        do { try operation(); check(name, false) }
        catch let failure as RuntimeUpdateFailure { check(name, expected == nil || failure == expected) }
        catch { check(name, false) }
    }
    guard let physicalTemporary = realpath(FileManager.default.temporaryDirectory.path, nil) else {
        check("physical_temporary_directory", false); return results
    }
    let temporary = URL(fileURLWithPath: String(cString: physicalTemporary), isDirectory: true)
    free(physicalTemporary)
    let root = temporary.appendingPathComponent("runtime-update-checks-" + UUID().uuidString)
    var sequence = 0
    func fixture() throws -> RuntimeUpdateFixture {
        sequence += 1
        return try RuntimeUpdateFixture(root: root.appendingPathComponent("case-\(sequence)"))
    }
    do { try RuntimePackageIO.createPrivateDirectory(root) }
    catch { check("fixture_root", false); return results }

    do {
        let empty = RuntimeUpdateConfiguration(channelURL: "")
        try empty.validate(); check("configuration_blank_disables_updates", empty.feedURL == nil)
        let valid = RuntimeUpdateConfiguration(channelURL: "https://updates.fixture.example/stable/channel.json")
        try valid.validate(); check("configuration_accepts_https_channel", valid.feedURL?.scheme == "https")
        for (name, value) in [
            ("http", "http://updates.fixture.example/channel.json"),
            ("file", "file:///private/tmp/channel.json"),
            ("credentials", "https://user:password@updates.fixture.example/channel.json"),
            ("query", "https://updates.fixture.example/channel.json?token=fixture"),
            ("fragment", "https://updates.fixture.example/channel.json#release"),
            ("wrong_basename", "https://updates.fixture.example/stable/latest.json"),
            ("relative", "/stable/channel.json"), ("path_traversal", "https://updates.fixture.example/../channel.json"),
            ("encoded_traversal", "https://updates.fixture.example/%2e%2e/channel.json"),
            ("encoded_slash", "https://updates.fixture.example/release%2fprivate/channel.json")
        ] {
            reject("configuration_rejects_" + name, expected: .invalidSource) {
                try RuntimeUpdateConfiguration(channelURL: value).validate()
            }
        }
        let suite = "RuntimeUpdateFixture." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw RuntimeUpdateFailure.persistenceFailed }
        defer { defaults.removePersistentDomain(forName: suite) }
        let configStore = RuntimeUpdateConfigurationStore(defaults: defaults)
        check("configuration_default_blank", try configStore.load().channelURL.isEmpty)
        try configStore.save(valid)
        check("configuration_save_readback", try configStore.load() == valid)
        check("configuration_restart_readback", try RuntimeUpdateConfigurationStore(defaults: defaults).load() == valid)
        let saved = defaults.persistentDomain(forName: suite) ?? [:]
        reject("configuration_invalid_save_rejected", expected: .invalidSource) {
            try configStore.save(.init(channelURL: "http://updates.fixture.example/channel.json"))
        }
        check("configuration_failed_save_retains_previous", try configStore.load() == valid)
        check("configuration_has_one_owned_key", saved.count == 1)
        for key in saved.keys { defaults.set("corrupt fixture update state", forKey: key) }
        reject("configuration_corrupt_state_is_error") { _ = try configStore.load() }
        check("configuration_corrupt_state_not_silently_replaced", saved.keys.allSatisfy {
            defaults.string(forKey: $0) == "corrupt fixture update state"
        })
        for key in saved.keys {
            defaults.set(Data("{\"schema\":\"runtime-update-source/v2\",\"channelURL\":\"\"}".utf8), forKey: key)
        }
        reject("configuration_unknown_persisted_schema_is_error") { _ = try configStore.load() }
        defaults.setPersistentDomain(saved, forName: suite)
        check("configuration_explicit_restore_recovers_state", try configStore.load() == valid)
    } catch { check("configuration_fixture", false) }

    do {
        let fixture = try fixture(), package = try fixture.package()
        let raw = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
        let channel = try fixture.channel(package)
        let verified = try RuntimeUpdateChannel.verify(channel, trust: fixture.trust, appVersion: "0.12.1")
        check("channel_signature_uses_exact_original_bytes", verified.bytes == raw && verified.id == "runtime-" + RuntimePackageIO.digest(raw))
        check("channel_retains_original_signature_bytes", verified.signatureBytes == (try Data(contentsOf: package.appendingPathComponent("signature.json"))))
        let baseline = try fixture.store().snapshot().current
        let release = try StdioRuntimeUpdateService.checkChannel(channel, feedURL: fixture.feedURL,
            current: baseline, trust: fixture.trust, appVersion: "0.12.1")
        check("channel_newer_release_available", release?.info.version == "1.1.0" && release?.id == verified.id)
        check("channel_total_matches_signed_inventory", release?.totalBytes == verified.manifest.files.reduce(0) { $0 + $1.size })
        let same = verified.manifest.info(id: "bundled")
        check("channel_same_version_is_up_to_date", try StdioRuntimeUpdateService.checkChannel(channel,
            feedURL: fixture.feedURL, current: same, trust: fixture.trust, appVersion: "0.12.1") == nil)
        let newer = RuntimePackageInfo(id: "bundled", version: "1.2.0", cliVersion: "2.1.295", sdkVersion: "0.3.295", nodeVersion: "26.7.0")
        check("channel_downgrade_is_not_offered", try StdioRuntimeUpdateService.checkChannel(channel,
            feedURL: fixture.feedURL, current: newer, trust: fixture.trust, appVersion: "0.12.1") == nil)
        reject("channel_http_source_rejected", expected: .invalidSource) {
            _ = try StdioRuntimeUpdateService.checkChannel(channel, feedURL: URL(string: "http://updates.fixture.example/channel.json")!,
                current: baseline, trust: fixture.trust, appVersion: "0.12.1")
        }
        reject("channel_unknown_signer_rejected", expected: .untrustedSigner) {
            let other = try fixture.package()
            try fixture.sign(other, manifestBytes: Data(contentsOf: other.appendingPathComponent("manifest.json")), signer: .init())
            _ = try RuntimeUpdateChannel.verify(fixture.channel(other), trust: fixture.trust, appVersion: "0.12.1")
        }
        reject("channel_modified_manifest_rejected", expected: .integrityFailed) {
            let other = try fixture.package()
            try fixture.mutateManifest(other, resign: false) { $0["version"] = "1.9.0" }
            _ = try RuntimeUpdateChannel.verify(fixture.channel(other), trust: fixture.trust, appVersion: "0.12.1")
        }
        reject("channel_incompatible_release_rejected", expected: .incompatible) {
            let other = try fixture.package()
            try fixture.mutateManifest(other) {
                $0["minimumAppVersion"] = "0.13.0"; $0["maximumAppVersionExclusive"] = "0.14.0"
            }
            _ = try RuntimeUpdateChannel.verify(fixture.channel(other), trust: fixture.trust, appVersion: "0.12.1")
        }
        reject("channel_invalid_signed_path_rejected") {
            let other = try fixture.package()
            try fixture.mutateManifest(other) {
                var files = $0["files"] as! [[String: Any]]; files[0]["path"] = "../private.key"; $0["files"] = files
            }
            _ = try RuntimeUpdateChannel.verify(fixture.channel(other), trust: fixture.trust, appVersion: "0.12.1")
        }
        reject("channel_invalid_schema_rejected") {
            _ = try RuntimeUpdateChannel.verify(fixture.channel(package) { $0["schema"] = "untrusted-channel/v2" },
                                               trust: fixture.trust, appVersion: "0.12.1")
        }
        reject("channel_invalid_base64_rejected") {
            _ = try RuntimeUpdateChannel.verify(fixture.channel(package) { $0["manifestBase64"] = "%%%" },
                                               trust: fixture.trust, appVersion: "0.12.1")
        }
        reject("channel_oversized_response_rejected") {
            _ = try RuntimeUpdateChannel.verify(Data(repeating: 32, count: 3 * 1024 * 1024 + 1),
                                               trust: fixture.trust, appVersion: "0.12.1")
        }
    } catch { check("channel_fixture", false) }

    do {
        let fixture = try fixture(), store = fixture.store(), service = RuntimeUpdateHeldFixtureService(fixture: fixture, package: try fixture.package())
        let configStore = MemoryRuntimeUpdateConfigurationStore(configuration: .init(channelURL: fixture.feedURL.absoluteString))
        let model = RuntimeVersionViewModel(store: store, registry: .init(), updater: service, updateConfigurationStore: configStore)
        let baseline = try store.snapshot()
        service.hold(check: true)
        let task = Task { await model.checkForUpdates() }
        let reached = await runtimeUpdateAwait { service.reachedCheck }
        check("model_checking_state", reached && model.isBusy && model.onlineOperation && !model.isTerminationWorkSettled)
        check("model_check_busy_guards", !model.canCheckUpdates && !model.canInstallUpdate && !model.canImport && !model.canRollback)
        await model.checkForUpdates(); await model.installUpdate()
        check("model_check_does_not_start_twice", service.checkCount == 1 && service.downloadCount == 0)
        model.cancelImport(); await task.value
        check("model_check_cancel_retains_current", !model.isBusy && model.error != nil && model.snapshot == baseline && !service.didExpire)
        service.hold()
        await model.checkForUpdates()
        check("model_check_retry_offers_release", model.availableUpdate?.info.version == "1.1.0" && model.error == nil && !model.isBusy)
        model.beginTermination()
    } catch { check("model_check_fixture", false) }

    do {
        let fixture = try fixture(), store = fixture.store(), service = RuntimeUpdateHeldFixtureService(fixture: fixture, package: try fixture.package())
        let configStore = MemoryRuntimeUpdateConfigurationStore(configuration: .init(channelURL: fixture.feedURL.absoluteString))
        let registry = OwnedProcessRegistry(), worker = OwnedProcessController()
        let model = RuntimeVersionViewModel(store: store, registry: registry, updater: service, updateConfigurationStore: configStore)
        let baseline = try store.snapshot()
        await model.checkForUpdates(); let available = model.availableUpdate
        service.hold(download: true)
        let task = Task { await model.installUpdate() }
        let reached = await runtimeUpdateAwait { service.reachedDownload && model.progress > 0 }
        check("model_downloading_state", reached && model.isBusy && model.onlineOperation && model.snapshot == baseline)
        await model.installUpdate()
        check("model_download_does_not_start_twice", service.downloadCount == 1)
        model.cancelImport(); await task.value
        check("model_download_cancel_retains_old_release_for_retry", !model.isBusy && model.error != nil && model.snapshot == baseline && model.availableUpdate?.id == available?.id && !service.didExpire)
        service.hold(); try worker.registerWork(in: registry)
        await model.installUpdate()
        check("model_import_waits_for_active_worker", model.snapshot?.current == baseline.current && model.snapshot?.pending?.id == available?.id && !model.isBusy)
        check("model_pending_blocks_another_update", !model.canCheckUpdates && !model.canInstallUpdate)
        check("model_pending_survives_store_restart", try fixture.store().snapshot() == model.snapshot)
        check("model_old_launch_root_retained_while_pending", try store.resolvedRuntimeRoot() == fixture.bundleContents)
        worker.finish(); model.refresh()
        check("model_idle_activates_downloaded_runtime", model.snapshot?.current.id == available?.id && model.snapshot?.previous == baseline.current && model.snapshot?.pending == nil)
        model.beginTermination()
    } catch { check("model_download_fixture", false) }

    do {
        let fixture = try fixture(), store = fixture.store(), service = RuntimeUpdateHeldFixtureService(fixture: fixture, package: try fixture.package())
        let configStore = MemoryRuntimeUpdateConfigurationStore(configuration: .init(channelURL: fixture.feedURL.absoluteString))
        let model = RuntimeVersionViewModel(store: store, registry: .init(), isApplicationIdle: { false }, updater: service, updateConfigurationStore: configStore)
        let baseline = try store.snapshot()
        await model.checkForUpdates(); let available = model.availableUpdate
        service.failNextDownload(.healthFailed); await model.installUpdate()
        check("model_health_failure_retains_old_current", model.error != nil && !model.isBusy && model.snapshot == baseline && model.availableUpdate?.id == available?.id)
        check("model_health_failure_keeps_catalog_unchanged", try store.snapshot() == baseline)
        await model.installUpdate()
        check("model_failed_download_can_retry", model.error == nil && model.snapshot?.pending?.id == available?.id && service.downloadCount == 2)
        model.cancelPending()
        check("model_cancel_pending_keeps_current", model.snapshot?.current == baseline.current && model.snapshot?.pending == nil)
        model.beginTermination()
    } catch { check("model_error_retry_fixture", false) }

    do {
        let fixture = try fixture(), store = fixture.store(), service = RuntimeUpdateHeldFixtureService(fixture: fixture, package: try fixture.package(version: "1.0.0"))
        let configs = MemoryRuntimeUpdateConfigurationStore(configuration: .init(channelURL: ""))
        let model = RuntimeVersionViewModel(store: store, registry: .init(), updater: service, updateConfigurationStore: configs)
        check("model_empty_source_disables_check", !model.canCheckUpdates && !model.canInstallUpdate)
        model.updateSource = "http://updates.fixture.example/channel.json"; model.saveUpdateSource()
        check("model_invalid_source_retains_saved_configuration", try model.error != nil && configs.load().channelURL.isEmpty)
        model.updateSource = fixture.feedURL.absoluteString; model.saveUpdateSource()
        check("model_valid_source_is_saved", try model.error == nil && configs.load().channelURL == fixture.feedURL.absoluteString && model.canCheckUpdates)
        await model.checkForUpdates()
        check("model_up_to_date_has_no_release", model.error == nil && model.availableUpdate == nil && !model.canInstallUpdate && !model.isBusy)
        model.beginTermination()
    } catch { check("model_source_up_to_date_fixture", false) }

    do { try RuntimePackageIO.removeOwnedStaging(root); check("fixture_teardown", !FileManager.default.fileExists(atPath: root.path)) }
    catch { check("fixture_teardown", false) }
    return results
}
