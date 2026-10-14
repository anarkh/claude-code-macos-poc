import CryptoKit
import Darwin
import Foundation

/// Small, inert local-build candidates. These checks never invoke the builder, VM, network,
/// real signing keys, credentials, or the production RuntimePackages directory.
private struct LocalRuntimePackageFixture {
    let root: URL
    let bundleContents: URL
    let storageRoot: URL
    let publisher = Curve25519.Signing.PrivateKey()

    init(root: URL) throws {
        self.root = root
        bundleContents = root.appendingPathComponent("Fixture.app/Contents")
        storageRoot = root.appendingPathComponent("private-store")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: bundleContents, withIntermediateDirectories: true)
        let manifest = try Self.writeContents(bundleContents, cliVersion: "2.1.294", sdkVersion: "0.3.294")
        try LocalRuntimePackageIO.encode(manifest).write(to: bundleContents.appendingPathComponent("Resources/BundledRuntimeManifest.json"))
        let key = publisher.publicKey.rawRepresentation
        try LocalRuntimePackageIO.encode(RuntimePackageTrust(schema: RuntimePackageTrust.schemaValue,
                publicKeys: [RuntimePackageIO.digest(key): key.base64EncodedString()]))
            .write(to: bundleContents.appendingPathComponent("Resources/RuntimeTrust.json"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.12.0"],
                                           format: .xml, options: 0).write(to: bundleContents.appendingPathComponent("Info.plist"))
    }

    func store() -> RuntimePackageStore { .init(bundleContents: bundleContents, storageRoot: storageRoot) }

    func candidate(cliVersion: String = "2.1.295", sdkVersion: String = "0.3.295") throws -> (URL, LocalRuntimeBuildProvenance) {
        let contents = root.appendingPathComponent("candidate-" + UUID().uuidString + "/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let manifest = try Self.writeContents(contents, cliVersion: cliVersion, sdkVersion: sdkVersion)
        let provenance = try LocalRuntimeBuildProvenance(validatedContents: contents, validatedManifest: manifest,
                    sdkArchiveSHA256: Self.hash("fixture SDK " + sdkVersion), cliSHA256: Self.hash("fixture CLI " + cliVersion),
                    cliManifestSHA256: Self.hash("fixture official CLI manifest " + cliVersion),
                    cliSigningKeySHA256: Self.hash("fixture official CLI signer"), builderRecipeSHA256: Self.hash("fixture builder recipe"))
        return (contents, provenance)
    }

    func installed(_ info: RuntimePackageInfo) -> URL {
        storageRoot.appendingPathComponent("local-versions/" + info.id)
    }

    func publishedPackage() throws -> URL {
        let package = root.appendingPathComponent("publisher-" + UUID().uuidString + ".clauderuntime")
        let contents = package.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let manifest = try Self.writeContents(contents, cliVersion: "2.1.298", sdkVersion: "0.3.298")
        let bytes = try LocalRuntimePackageIO.encode(manifest)
        try bytes.write(to: package.appendingPathComponent("manifest.json"))
        let signature = RuntimePackageSignature(schema: RuntimePackageSignature.schemaValue,
                            keyID: RuntimePackageIO.digest(publisher.publicKey.rawRepresentation),
                            signature: try publisher.signature(for: bytes).base64EncodedString())
        try LocalRuntimePackageIO.encode(signature).write(to: package.appendingPathComponent("signature.json"))
        return package
    }

    static func hash(_ value: String) -> String { RuntimePackageIO.digest(Data(value.utf8)) }

    private static func writeContents(_ contents: URL, cliVersion: String, sdkVersion: String) throws -> RuntimePackageManifest {
        let manager = FileManager.default
        var payloads = Dictionary(uniqueKeysWithValues: RuntimePackageManifest.requiredPaths.map {
            ($0, Data(("inert local build " + cliVersion + " " + $0).utf8))
        })
        let prefix = "Resources/Runtime/host/text-runtime/images/"
        let disk = payloads[RuntimePackageManifest.diskPath]!
        payloads[prefix + "base.json"] = try JSONSerialization.data(withJSONObject:
            ["schema": "claude-text-vm-base/v1", "prepared": true, "no_user_data": true,
             "network_devices": 0, "directory_shares": 0, "node_version": "26.7.0",
             "sdk_version": sdkVersion, "cli_version": cliVersion, "linux_cli_sha256": hash("fixture CLI " + cliVersion),
             "disk_bytes": disk.count, "disk_sha256": RuntimePackageIO.digest(disk),
             "kernel_sha256": RuntimePackageIO.digest(payloads[prefix + "kernel"]!),
             "initrd_sha256": RuntimePackageIO.digest(payloads[prefix + "initrd"]!)], options: [.sortedKeys])
        payloads["Resources/Runtime/host/text-runtime/runtime-config.json"] = try JSONSerialization.data(withJSONObject:
            ["schema": "claude-vm-runtime/v1", "image_dir": "images", "runner": "../../../../Helpers/vm-text-runtime",
             "guest_runtime_dir": "../../guest/text-runtime", "python": "/usr/bin/python3"], options: [.sortedKeys])
        payloads["Resources/Runtime/sdk/package.json"] = try JSONSerialization.data(withJSONObject:
            ["name": "local-runtime-offline-fixture", "dependencies": ["@anthropic-ai/claude-agent-sdk": sdkVersion]],
            options: [.sortedKeys])
        var files: [RuntimePackageFile] = []
        for path in payloads.keys.sorted() {
            let url = contents.appendingPathComponent(path), bytes = payloads[path]!
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            let executable = path == "Helpers/vm-text-runtime" || path.hasSuffix(".sh")
            try manager.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: url.path)
            files.append(.init(path: path, size: Int64(bytes.count), sha256: RuntimePackageIO.digest(bytes), executable: executable))
        }
        return .init(schema: RuntimePackageManifest.schemaValue, version: cliVersion, cliVersion: cliVersion,
                     sdkVersion: sdkVersion, nodeVersion: "26.7.0", hostProtocol: 1, platform: "macOS-arm64",
                     minimumOSVersion: "14.0.0", minimumAppVersion: "0.12.0", maximumAppVersionExclusive: "0.13.0", files: files)
    }
}

private final class LocalRuntimeCancelFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var lastProgress = 0.0
    func receive(_ value: Double) { lock.lock(); lastProgress = value; lock.unlock() }
    var shouldCancel: Bool { lock.lock(); defer { lock.unlock() }; return lastProgress >= 0.55 }
}

private enum LocalRuntimeCommitHookError: Error, Equatable { case cleanupFailed }

private final class LocalRuntimeCommitHookFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func invoked() { lock.lock(); count += 1; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private func localRuntimeRemoveFixture(_ root: URL) throws {
    func writable(_ directory: URL) throws {
        guard chmod(directory.path, 0o700) == 0 else { throw RuntimePackageFailure.persistenceFailed }
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            var metadata = stat()
            guard lstat(child.path, &metadata) == 0 else { throw RuntimePackageFailure.persistenceFailed }
            if metadata.st_mode & S_IFMT == S_IFDIR { try writable(child) }
        }
    }
    try writable(root)
    try FileManager.default.removeItem(at: root)
}

@MainActor
func localRuntimePackageChecks() async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    func check(_ name: String, _ passed: Bool) { checks["local_runtime_package_" + name] = passed }
    guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else {
        return ["local_runtime_package_physical_temp": false]
    }
    let temporary = URL(fileURLWithPath: String(cString: path))
    free(path)
    let root = temporary.appendingPathComponent("local-runtime-checks-" + UUID().uuidString)
    do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    catch { return ["local_runtime_package_fixture_setup": false] }
    var caseNumber = 0
    func fixture() throws -> LocalRuntimePackageFixture {
        caseNumber += 1
        return try .init(root: root.appendingPathComponent("case-\(caseNumber)"))
    }
    func failure(_ name: String, _ expected: [RuntimePackageFailure], _ operation: () throws -> Void) {
        do { try operation(); check(name, false) }
        catch let error as RuntimePackageFailure { check(name, expected.contains(error)) }
        catch { check(name, false) }
    }
    do {
        let fixture = try fixture(), store = fixture.store(), baseline = try store.snapshot()
        let source = try fixture.candidate()
        let trustURL = fixture.bundleContents.appendingPathComponent("Resources/RuntimeTrust.json")
        let publisherTrust = try Data(contentsOf: trustURL)
        let imported = try store.importLocalBuild(at: source.0, provenance: source.1, shouldCancel: { false }, progress: { _ in })
        let pending = try fixture.store().snapshot()
        check("local_id_and_cli_runtime_version", imported.id.hasPrefix("local-") && imported.version == "2.1.295")
        check("import_stages_without_switching", pending.pending == imported && pending.current == baseline.current && pending.previous == nil)
        check("publisher_trust_is_unchanged", try Data(contentsOf: trustURL) == publisherTrust)
        check("local_package_exact_root", Set(try FileManager.default.contentsOfDirectory(atPath: fixture.installed(imported).path)) == Set(["Contents", "manifest.json", "signature.json"]))
        let privateKey = try RuntimePackageIO.statFile(fixture.storageRoot.appendingPathComponent("local-trust/signing-key.raw"))
        check("local_key_is_private", privateKey.st_mode & 0o777 == 0o600 && privateKey.st_size == 32 && privateKey.st_uid == getuid())
        try store.activatePending()
        let activated = try fixture.store().snapshot()
        check("activation_survives_restart", activated.current == imported && activated.previous == baseline.bundled && activated.pending == nil)
        check("resolution_uses_local_domain", try fixture.store().resolvedRuntimeRoot() == fixture.installed(imported).appendingPathComponent("Contents"))
        try FileManager.default.removeItem(at: source.0.deletingLastPathComponent())
        check("source_removal_is_independent", try fixture.store().resolvedRuntimeRoot() == fixture.installed(imported).appendingPathComponent("Contents"))
        try store.requestRollback()
        check("rollback_is_pending_until_activation", try fixture.store().snapshot().pending == baseline.bundled)
        try store.activatePending()
        let rolledBack = try fixture.store().snapshot()
        check("rollback_to_bundle_preserves_local_previous", rolledBack.current == baseline.bundled && rolledBack.previous == imported)
        try store.requestRollback(); try store.activatePending()
        check("rollback_back_to_local_survives_restart", try fixture.store().snapshot().current == imported)
        let cancellationSource = try fixture.candidate(cliVersion: "2.1.296", sdkVersion: "0.3.296")
        let stateURL = fixture.storageRoot.appendingPathComponent("state.json")
        let stateBefore = try Data(contentsOf: stateURL), selection = try store.snapshot()
        let cancellation = LocalRuntimeCancelFixture()
        failure("cancel_copy_is_explicit", [.cancelled]) {
            _ = try store.importLocalBuild(at: cancellationSource.0, provenance: cancellationSource.1,
                                           shouldCancel: { cancellation.shouldCancel }, progress: { cancellation.receive($0) })
        }
        check("cancel_preserves_exact_state", try Data(contentsOf: stateURL) == stateBefore && fixture.store().snapshot() == selection)
        check("cancel_removes_owned_staging", !(try FileManager.default.contentsOfDirectory(atPath: fixture.storageRoot.path)).contains { $0.hasPrefix(".staging-") })
        let other = try fixture.candidate(cliVersion: "2.1.297", sdkVersion: "0.3.297")
        failure("provenance_cannot_be_used_for_different_candidate", [.invalidPackage]) {
            _ = try store.importLocalBuild(at: other.0, provenance: cancellationSource.1, shouldCancel: { false }, progress: { _ in })
        }
        let external = fixture.root.appendingPathComponent("local-as-external.clauderuntime")
        try FileManager.default.copyItem(at: fixture.installed(imported), to: external)
        failure("local_signature_cannot_authorize_external_import", [.untrustedSigner]) {
            _ = try store.importPackage(at: external, shouldCancel: { false }, progress: { _ in })
        }
        let unsigned = fixture.root.appendingPathComponent("unsigned.clauderuntime")
        try FileManager.default.createDirectory(at: unsigned, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: unsigned.appendingPathComponent("manifest.json"))
        failure("unsigned_external_import_remains_rejected", [.invalidPackage]) {
            _ = try store.importPackage(at: unsigned, shouldCancel: { false }, progress: { _ in })
        }
        check("rejected_external_imports_preserve_state", try Data(contentsOf: stateURL) == stateBefore && fixture.store().snapshot() == selection)
        let published = try store.importPackage(at: fixture.publishedPackage(), shouldCancel: { false }, progress: { _ in })
        try store.activatePending()
        let mixed = try fixture.store().snapshot()
        check("published_activation_retains_local_previous", published.id.hasPrefix("runtime-") && mixed.current == published && mixed.previous == imported)
        try store.requestRollback(); try store.activatePending()
        let mixedRollback = try fixture.store().snapshot()
        check("mixed_source_rollback_survives_restart", mixedRollback.current == imported && mixedRollback.previous == published && mixedRollback.pending == nil)
    } catch { check("lifecycle_fixture", false) }

    for hookResult in ["failure", "success"] {
        do {
            let fixture = try fixture(), store = fixture.store(), initial = try fixture.candidate()
            _ = try store.importLocalBuild(at: initial.0, provenance: initial.1, shouldCancel: { false }, progress: { _ in })
            try store.activatePending()
            let before = try store.snapshot(), stateURL = fixture.storageRoot.appendingPathComponent("state.json")
            let stateBytes = try Data(contentsOf: stateURL)
            let versionsURL = fixture.storageRoot.appendingPathComponent("local-versions")
            let receiptsURL = fixture.storageRoot.appendingPathComponent("local-receipts")
            let oldVersions = Set(try FileManager.default.contentsOfDirectory(atPath: versionsURL.path))
            let oldReceipts = Set(try FileManager.default.contentsOfDirectory(atPath: receiptsURL.path))
            let candidate = try fixture.candidate(cliVersion: "2.1.296", sdkVersion: "0.3.296")
            let scratch = candidate.0.deletingLastPathComponent(), hook = LocalRuntimeCommitHookFixture()
            if hookResult == "failure" {
                do {
                    _ = try store.importLocalBuild(at: candidate.0, provenance: candidate.1,
                        shouldCancel: { false }, progress: { _ in }, beforeCommit: {
                            hook.invoked()
                            throw LocalRuntimeCommitHookError.cleanupFailed
                        })
                    check("precommit_failure_preserves_original_error", false)
                } catch let error as LocalRuntimeCommitHookError {
                    check("precommit_failure_preserves_original_error", error == .cleanupFailed)
                } catch { check("precommit_failure_preserves_original_error", false) }
                check("precommit_failure_preserves_exact_state", try store.snapshot() == before && Data(contentsOf: stateURL) == stateBytes)
                let currentVersions = Set(try FileManager.default.contentsOfDirectory(atPath: versionsURL.path))
                let currentReceipts = Set(try FileManager.default.contentsOfDirectory(atPath: receiptsURL.path))
                check("precommit_failure_commits_no_version_or_receipt", currentVersions == oldVersions && currentReceipts == oldReceipts)
                check("precommit_failure_cleans_owned_staging", !(try FileManager.default.contentsOfDirectory(atPath: fixture.storageRoot.path)).contains { $0.hasPrefix(".staging-") })
            } else {
                let imported = try store.importLocalBuild(at: candidate.0, provenance: candidate.1,
                    shouldCancel: { false }, progress: { _ in }, beforeCommit: {
                        hook.invoked()
                        try FileManager.default.removeItem(at: scratch)
                        guard !FileManager.default.fileExists(atPath: scratch.path) else { throw LocalRuntimeCommitHookError.cleanupFailed }
                    })
                let pending = try fixture.store().snapshot()
                check("precommit_success_caches_source_before_cleanup", !FileManager.default.fileExists(atPath: candidate.0.path) && pending.current == before.current && pending.pending == imported)
                try store.activatePending()
                check("precommit_success_activates_independent_copy", try fixture.store().resolvedRuntimeRoot() == fixture.installed(imported).appendingPathComponent("Contents"))
            }
            check("precommit_" + hookResult + "_hook_runs_once", hook.calls == 1)
        } catch { check("precommit_" + hookResult + "_fixture", false) }
    }

    for tamper in ["manifest", "payload", "receipt", "public_trust", "base_cli_digest"] {
        do {
            let fixture = try fixture(), store = fixture.store(), source = try fixture.candidate()
            let imported = try store.importLocalBuild(at: source.0, provenance: source.1, shouldCancel: { false }, progress: { _ in })
            try store.activatePending()
            let stateURL = fixture.storageRoot.appendingPathComponent("state.json"), stateBefore = try Data(contentsOf: stateURL)
            let url: URL
            switch tamper {
            case "manifest": url = fixture.installed(imported).appendingPathComponent("manifest.json")
            case "payload": url = fixture.installed(imported).appendingPathComponent("Contents/Resources/Runtime/translation/stdio.mjs")
            case "receipt": url = fixture.storageRoot.appendingPathComponent("local-receipts/" + imported.id + ".json")
            case "public_trust": url = fixture.storageRoot.appendingPathComponent("local-trust/trust.json")
            default: url = fixture.installed(imported).appendingPathComponent("Contents/Resources/Runtime/host/text-runtime/images/base.json")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try Data("tampered inert local fixture".utf8).write(to: url)
            failure(tamper + "_launch_rejected_after_restart", [.integrityFailed, .invalidPackage]) {
                _ = try fixture.store().resolvedRuntimeRoot()
            }
            check(tamper + "_never_changes_selection", try Data(contentsOf: stateURL) == stateBefore && fixture.store().snapshot().current.id == imported.id)
        } catch { check(tamper + "_fixture", false) }
    }
    do { try localRuntimeRemoveFixture(root); check("fixture_teardown", !FileManager.default.fileExists(atPath: root.path)) }
    catch { check("fixture_teardown", false) }
    return checks
}
