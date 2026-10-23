import CryptoKit
import Darwin
import Foundation

// All bundles, payloads, keys, receipts and stores below are inert temporary fixtures.
// The injected health check never launches a process, VM or network connection.
private enum FixtureFailure: Error { case assertion(String), health, filesystem }

private func require(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
    guard try condition() else { throw FixtureFailure.assertion(label) }
}

private struct FileEvidence: Equatable {
    let mode: mode_t
    let uid: uid_t
    let gid: gid_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let digest: String?
}

private func evidence(_ root: URL) throws -> [String: FileEvidence] {
    var result: [String: FileEvidence] = [:]
    func visit(_ url: URL, relative: String) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { throw FixtureFailure.filesystem }
        let kind = metadata.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR else { throw FixtureFailure.filesystem }
        result[relative] = .init(mode: metadata.st_mode, uid: metadata.st_uid, gid: metadata.st_gid,
            size: metadata.st_size, modifiedSeconds: metadata.st_mtimespec.tv_sec,
            modifiedNanoseconds: metadata.st_mtimespec.tv_nsec,
            digest: kind == S_IFREG ? RuntimePackageIO.digest(try Data(contentsOf: url)) : nil)
        if kind == S_IFDIR {
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                try visit(url.appendingPathComponent(name), relative: relative + "/" + name)
            }
        }
    }
    try visit(root, relative: ".")
    return result
}

private func removeFixture(_ root: URL) throws {
    func writable(_ directory: URL) throws {
        guard chmod(directory.path, 0o700) == 0 else { throw FixtureFailure.filesystem }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else { throw FixtureFailure.filesystem }
            if metadata.st_mode & S_IFMT == S_IFDIR { try writable(url) }
        }
    }
    try writable(root)
    try FileManager.default.removeItem(at: root)
}

private struct ReissueFixture {
    let root: URL
    let oldBundle: URL
    let newBundle: URL
    let sourceStorage: URL
    let targetStorage: URL
    let node: URL
    let original: RuntimePackageInfo
    let metadata: LocalRuntimeBuildMetadata

    var originalDirectory: URL { sourceStorage.appendingPathComponent("local-versions/" + original.id) }
    var targetOriginalDirectory: URL { targetStorage.appendingPathComponent("local-versions/" + original.id) }
    var sourceReceipt: URL { sourceStorage.appendingPathComponent("local-receipts/" + original.id + ".json") }
    var targetReceipt: URL { targetStorage.appendingPathComponent("local-receipts/" + original.id + ".json") }

    var options: ReissueLocalRuntime.Options {
        .init(oldBundle: oldBundle, newBundle: newBundle, sourceStorage: sourceStorage,
              targetStorage: targetStorage, node: node)
    }

    init(root: URL, sameStorage: Bool = false) throws {
        self.root = root
        oldBundle = root.appendingPathComponent("Old.app/Contents")
        newBundle = root.appendingPathComponent("New.app/Contents")
        sourceStorage = root.appendingPathComponent("source-store")
        targetStorage = sameStorage ? sourceStorage : root.appendingPathComponent("target-store")
        node = root.appendingPathComponent("inert-node")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let publisher = Curve25519.Signing.PrivateKey()
        let publicKey = publisher.publicKey.rawRepresentation
        let trust = RuntimePackageTrust(schema: RuntimePackageTrust.schemaValue,
            publicKeys: [RuntimePackageIO.digest(publicKey): publicKey.base64EncodedString()])
        for (contents, upper, appVersion) in [(oldBundle, "0.13.0", "0.12.0"), (newBundle, "0.14.0", "0.13.3")] {
            let manifest = try Self.writeContents(contents, cli: "2.1.294", sdk: "0.3.294", upper: upper)
            try LocalRuntimePackageIO.encode(manifest).write(to: contents.appendingPathComponent("Resources/BundledRuntimeManifest.json"))
            try LocalRuntimePackageIO.encode(trust).write(to: contents.appendingPathComponent("Resources/RuntimeTrust.json"))
            try Self.writeAppVersion(appVersion, at: contents)
        }
        try Data("#!/bin/sh\nexit 88\n".utf8).write(to: node)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
        let candidate = root.appendingPathComponent("candidate/Contents")
        let manifest = try Self.writeContents(candidate, cli: "2.1.295", sdk: "0.3.295", upper: "0.13.0")
        let provenance = try LocalRuntimeBuildProvenance(validatedContents: candidate, validatedManifest: manifest,
            sdkArchiveSHA256: Self.hash("fixture SDK archive"), cliSHA256: Self.hash("fixture CLI 2.1.295"),
            cliManifestSHA256: Self.hash("fixture CLI manifest"), cliSigningKeySHA256: Self.hash("fixture CLI signer"),
            builderRecipeSHA256: Self.hash("fixture builder recipe"))
        metadata = provenance.metadata
        let store = RuntimePackageStore(bundleContents: oldBundle, storageRoot: sourceStorage)
        original = try store.importLocalBuild(at: candidate, provenance: provenance,
            shouldCancel: { false }, progress: { _ in })
        try store.activatePending()
        try Self.writeAppVersion("0.13.2", at: oldBundle)
        if !sameStorage { try FileManager.default.copyItem(at: sourceStorage, to: targetStorage) }
    }

    static func writeAppVersion(_ version: String, at contents: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version],
            format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    }

    static func hash(_ value: String) -> String { RuntimePackageIO.digest(Data(value.utf8)) }

    private static func writeContents(_ contents: URL, cli: String, sdk: String, upper: String) throws -> RuntimePackageManifest {
        var payload = Dictionary(uniqueKeysWithValues: RuntimePackageManifest.requiredPaths.map {
            ($0, Data(("inert fixture " + cli + " " + $0).utf8))
        })
        let prefix = "Resources/Runtime/host/text-runtime/images/"
        let disk = payload[RuntimePackageManifest.diskPath]!
        payload[prefix + "base.json"] = try JSONSerialization.data(withJSONObject: [
            "schema": "claude-text-vm-base/v1", "prepared": true, "no_user_data": true,
            "network_devices": 0, "directory_shares": 0, "node_version": "26.7.0",
            "sdk_version": sdk, "cli_version": cli, "linux_cli_sha256": hash("fixture CLI " + cli),
            "disk_bytes": disk.count, "disk_sha256": RuntimePackageIO.digest(disk),
            "kernel_sha256": RuntimePackageIO.digest(payload[prefix + "kernel"]!),
            "initrd_sha256": RuntimePackageIO.digest(payload[prefix + "initrd"]!)
        ], options: [.sortedKeys])
        payload["Resources/Runtime/host/text-runtime/runtime-config.json"] = try JSONSerialization.data(withJSONObject: [
            "schema": "claude-vm-runtime/v1", "image_dir": "images", "runner": "../../../../Helpers/vm-text-runtime",
            "guest_runtime_dir": "../../guest/text-runtime", "python": "/usr/bin/python3"
        ], options: [.sortedKeys])
        payload["Resources/Runtime/sdk/package.json"] = try JSONSerialization.data(withJSONObject: [
            "name": "reissue-offline-fixture", "dependencies": ["@anthropic-ai/claude-agent-sdk": sdk]
        ], options: [.sortedKeys])
        var files: [RuntimePackageFile] = []
        for path in payload.keys.sorted() {
            let url = contents.appendingPathComponent(path), bytes = payload[path]!
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            let executable = path == "Helpers/vm-text-runtime" || path.hasSuffix(".sh")
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: url.path)
            files.append(.init(path: path, size: Int64(bytes.count), sha256: RuntimePackageIO.digest(bytes), executable: executable))
        }
        return .init(schema: RuntimePackageManifest.schemaValue, version: cli, cliVersion: cli,
            sdkVersion: sdk, nodeVersion: "26.7.0", hostProtocol: 1, platform: "macOS-arm64",
            minimumOSVersion: "14.0.0", minimumAppVersion: "0.12.0", maximumAppVersionExclusive: upper, files: files)
    }
}

@main
private enum ReissueLocalRuntimeChecks {
    static func main() throws {
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw FixtureFailure.filesystem
        }
        let temporary = URL(fileURLWithPath: String(cString: physical))
        free(physical)
        let root = temporary.appendingPathComponent("reissue-runtime-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var failures: [String] = []
        func run(_ label: String, _ operation: () throws -> Void) {
            do { try operation(); print("PASS " + label) }
            catch { failures.append(label); print("FAIL \(label): \(error)") }
        }
        for sameStorage in [false, true] {
          run(sameStorage ? "same_store_reissue_and_activation" : "copied_store_reissue_and_activation") {
            let fixture = try ReissueFixture(root: root.appendingPathComponent(sameStorage ? "success-same" : "success-copy"), sameStorage: sameStorage)
            let sourceBefore = try evidence(fixture.sourceStorage)
            let oldBefore = try evidence(fixture.targetOriginalDirectory)
            let receiptBefore = try evidence(fixture.targetReceipt)
            let trustBefore = try evidence(fixture.targetStorage.appendingPathComponent("local-trust"))
            let bundlesBefore = [try evidence(fixture.oldBundle), try evidence(fixture.newBundle)]
            var healthCalls = 0
            _ = try ReissueLocalRuntime.execute(options: fixture.options) { bundle, runtime in
                healthCalls += 1
                try require(bundle == fixture.newBundle, "health uses candidate bundle")
                try require(runtime == fixture.originalDirectory.appendingPathComponent("Contents"), "health uses selected source payload")
            }
            let store = RuntimePackageStore(bundleContents: fixture.newBundle, storageRoot: fixture.targetStorage)
            let snapshot = try store.snapshot()
            try require(healthCalls == 1, "health runs exactly once")
            try require(snapshot.current.id.hasPrefix("local-") && snapshot.current.id != fixture.original.id, "new signed package ID")
            try require(snapshot.pending == nil, "activation finished")
            try require(snapshot.current.cliVersion == fixture.original.cliVersion && snapshot.current.sdkVersion == fixture.original.sdkVersion && snapshot.current.nodeVersion == fixture.original.nodeVersion, "versions preserved")
            let identity = try LocalRuntimePackageIO.loadIdentity(at: fixture.targetStorage.appendingPathComponent("local-trust"))
            let newDirectory = fixture.targetStorage.appendingPathComponent("local-versions/" + snapshot.current.id)
            let package = try LocalRuntimePackageIO.signedManifest(at: newDirectory, identity: identity)
            let original = try LocalRuntimePackageIO.signedManifest(at: fixture.originalDirectory, identity: identity)
            try require(package.manifest.files == original.manifest.files, "identical payload inventory")
            try require(package.manifest.maximumAppVersionExclusive == "0.14.0", "widened compatibility bound")
            try require(package.manifest.minimumAppVersion == original.manifest.minimumAppVersion && package.manifest.minimumOSVersion == original.manifest.minimumOSVersion && package.manifest.platform == original.manifest.platform && package.manifest.hostProtocol == original.manifest.hostProtocol, "other compatibility fields preserved")
            try require(try LocalRuntimePackageIO.verifyReceipt(at: fixture.targetStorage.appendingPathComponent("local-receipts/" + snapshot.current.id + ".json"), package: package, identity: identity) == fixture.metadata, "receipt provenance preserved")
            try RuntimePackageIO.verifyPayload(newDirectory.appendingPathComponent("Contents"), manifest: package.manifest, full: true, packageRoot: newDirectory)
            try require(try store.resolvedRuntimeRoot() == newDirectory.appendingPathComponent("Contents"), "resolution uses reissued payload")
            if !sameStorage { try require(try evidence(fixture.sourceStorage) == sourceBefore, "source store unchanged") }
            try require(try evidence(fixture.targetOriginalDirectory) == oldBefore, "old package bytes and metadata unchanged")
            try require(try evidence(fixture.targetReceipt) == receiptBefore, "old receipt unchanged")
            try require(try evidence(fixture.targetStorage.appendingPathComponent("local-trust")) == trustBefore, "local identity unchanged")
            try require([try evidence(fixture.oldBundle), try evidence(fixture.newBundle)] == bundlesBefore, "bundles unchanged")
          }
        }
        for fault in ["receipt_signature", "manifest_signature", "payload", "health"] {
            run(fault + "_failure_preserves_stores") {
                let fixture = try ReissueFixture(root: root.appendingPathComponent(fault))
                if fault == "payload" {
                    for directory in [fixture.originalDirectory, fixture.targetOriginalDirectory] {
                        let file = directory.appendingPathComponent("Contents/" + RuntimePackageManifest.diskPath)
                        var bytes = try Data(contentsOf: file)
                        bytes[bytes.startIndex] ^= 0xff
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                        try bytes.write(to: file)
                        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
                    }
                } else if fault != "health" {
                    let files = fault == "receipt_signature" ? [fixture.sourceReceipt, fixture.targetReceipt] : [fixture.originalDirectory.appendingPathComponent("signature.json"), fixture.targetOriginalDirectory.appendingPathComponent("signature.json")]
                    for file in files {
                        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                        object["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
                        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
                    }
                }
                let sourceBefore = try evidence(fixture.sourceStorage)
                let targetBefore = try evidence(fixture.targetStorage)
                var healthCalls = 0, rejected = false
                do {
                    _ = try ReissueLocalRuntime.execute(options: fixture.options) { _, _ in
                        healthCalls += 1
                        if fault == "health" { throw FixtureFailure.health }
                    }
                } catch { rejected = true }
                try require(rejected, "invalid reissue rejected")
                try require(healthCalls == (fault == "health" ? 1 : 0), "validation precedes health")
                try require(try evidence(fixture.sourceStorage) == sourceBefore, "source remains unchanged after rejection")
                try require(try evidence(fixture.targetStorage) == targetBefore, "target remains unchanged after rejection")
            }
        }
        run("fixture_teardown") { try removeFixture(root) }
        if !failures.isEmpty { exit(1) }
    }
}
