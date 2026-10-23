import CryptoKit
import Darwin
import Foundation

/// Explicit maintenance operation for an already signed local runtime whose App
/// compatibility ceiling was packaged incorrectly. It never edits that package.
enum ReissueLocalRuntime {
    struct Options: Sendable {
        let oldBundle: URL
        let newBundle: URL
        let sourceStorage: URL
        let targetStorage: URL
        let node: URL
    }

    enum Failure: String, Error {
        case arguments = "REISSUE_ARGUMENTS_INVALID"
        case policy = "REISSUE_POLICY_NOT_APPLICABLE"
        case sourceChanged = "REISSUE_SOURCE_CHANGED"
        case target = "REISSUE_TARGET_NOT_EMPTY_OR_MATCHING"
        case health = "REISSUE_HEALTH_FAILED"
        case cleanup = "REISSUE_HEALTH_CLEANUP_UNCONFIRMED"
        case readback = "REISSUE_READBACK_FAILED"
    }

    private struct State: Decodable {
        let schema: String
        let current: String?
        let previous: String?
        let pending: String?
    }

    private struct Source: Sendable {
        let id: String
        let package: RuntimePackageVerified
        let contents: URL
        let provenance: LocalRuntimeBuildMetadata
        let stateBytes: Data
        let manifestBytes: Data
        let signatureBytes: Data
        let receiptBytes: Data
    }

    private static func readBundle(_ contents: URL) throws -> (RuntimePackageManifest, String) {
        try RuntimePackageIO.validateAncestors(contents)
        let manifest = try RuntimePackageIO.decodeManifest(RuntimePackageIO.readSmall(
            contents.appendingPathComponent("Resources/BundledRuntimeManifest.json"), limit: RuntimePackageIO.maximumManifestBytes))
        let data = try RuntimePackageIO.readSmall(contents.appendingPathComponent("Info.plist"), limit: 128 * 1024)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String,
              RuntimePackageIO.isVersion(version) else { throw Failure.policy }
        return (manifest, version)
    }

    private static func readSource(_ storage: URL) throws -> Source {
        try RuntimePackageIO.validateAncestors(storage)
        let root = try RuntimePackageIO.statFile(storage, directory: true)
        let stateURL = storage.appendingPathComponent("state.json")
        let stateMetadata = try RuntimePackageIO.statFile(stateURL)
        guard root.st_uid == getuid(), root.st_mode & 0o777 == 0o700,
              stateMetadata.st_uid == getuid(), stateMetadata.st_mode & 0o777 == 0o600 else {
            throw RuntimePackageFailure.invalidState
        }
        let stateBytes = try RuntimePackageIO.readSmall(stateURL, limit: 16 * 1024)
        let state = try JSONDecoder().decode(State.self, from: stateBytes)
        guard state.schema == "claude-runtime-state/v1", state.pending == nil,
              let id = state.current, id.hasPrefix("local-"), RuntimePackageIO.isDigest(String(id.dropFirst(6))) else {
            throw Failure.policy
        }
        let directory = storage.appendingPathComponent("local-versions/" + id)
        let metadata = try RuntimePackageIO.statFile(directory, directory: true)
        guard metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o500 else {
            throw RuntimePackageFailure.integrityFailed
        }
        // Existing production APIs read the private key internally and verify its
        // public trust. Key bytes are never returned by this tool or copied out.
        let identity = try LocalRuntimePackageIO.loadIdentity(at: storage.appendingPathComponent("local-trust"))
        let package = try LocalRuntimePackageIO.signedManifest(at: directory, identity: identity)
        guard package.id == id, let signature = package.signatureBytes else { throw RuntimePackageFailure.integrityFailed }
        let receiptURL = storage.appendingPathComponent("local-receipts/" + id + ".json")
        let provenance = try LocalRuntimePackageIO.verifyReceipt(at: receiptURL, package: package, identity: identity)
        let contents = directory.appendingPathComponent("Contents")
        try LocalRuntimePackageIO.validateProvenancePayload(contents, provenance: provenance)
        try RuntimePackageIO.verifyPayload(contents, manifest: package.manifest, full: true, packageRoot: directory)
        return Source(id: id, package: package, contents: contents, provenance: provenance,
                      stateBytes: stateBytes, manifestBytes: package.bytes, signatureBytes: signature,
                      receiptBytes: try RuntimePackageIO.readSmall(receiptURL, limit: 16 * 1024))
    }

    private static func assertSourceMetadata(_ source: Source, storage: URL, includingState: Bool) throws {
        let directory = storage.appendingPathComponent("local-versions/" + source.id)
        guard try RuntimePackageIO.readSmall(directory.appendingPathComponent("manifest.json"), limit: RuntimePackageIO.maximumManifestBytes) == source.manifestBytes,
              try RuntimePackageIO.readSmall(directory.appendingPathComponent("signature.json"), limit: 4096) == source.signatureBytes,
              try RuntimePackageIO.readSmall(storage.appendingPathComponent("local-receipts/" + source.id + ".json"), limit: 16 * 1024) == source.receiptBytes else {
            throw Failure.sourceChanged
        }
        if includingState, try RuntimePackageIO.readSmall(storage.appendingPathComponent("state.json"), limit: 16 * 1024) != source.stateBytes {
            throw Failure.sourceChanged
        }
    }

    private static func samePolicy(_ a: RuntimePackageManifest, _ b: RuntimePackageManifest) -> Bool {
        a.hostProtocol == b.hostProtocol && a.platform == b.platform && a.minimumOSVersion == b.minimumOSVersion &&
            a.minimumAppVersion == b.minimumAppVersion && a.maximumAppVersionExclusive == b.maximumAppVersionExclusive
    }

    /// The executable always supplies runHealth. Only the separately compiled
    /// synthetic fixture runner injects a no-VM health operation.
    static func execute(options: Options, healthCheck: (URL, URL) throws -> Void) throws -> [String: Any] {
        guard options.oldBundle.path != options.newBundle.path else { throw Failure.arguments }
        func nested(_ a: URL, _ b: URL) -> Bool { a.path.hasPrefix(b.path + "/") || b.path.hasPrefix(a.path + "/") }
        guard !nested(options.sourceStorage, options.targetStorage),
              ![options.oldBundle, options.newBundle].contains(where: {
                  $0.path == options.targetStorage.path || nested($0, options.targetStorage)
              }) else { throw Failure.arguments }
        let (oldPolicy, oldVersion) = try readBundle(options.oldBundle)
        let (policy, version) = try readBundle(options.newBundle)
        try policy.validateCompatibility(appVersion: version)
        guard RuntimePackageIO.compareVersion(oldVersion, oldPolicy.maximumAppVersionExclusive) >= 0,
              RuntimePackageIO.compareVersion(version, oldVersion) >= 0,
              policy.hostProtocol == oldPolicy.hostProtocol, policy.platform == oldPolicy.platform,
              policy.minimumOSVersion == oldPolicy.minimumOSVersion,
              policy.minimumAppVersion == oldPolicy.minimumAppVersion,
              RuntimePackageIO.compareVersion(policy.maximumAppVersionExclusive, oldPolicy.maximumAppVersionExclusive) > 0 else {
            throw Failure.policy
        }
        // Validate the candidate App's trusted health probe before executing it.
        try RuntimePackageIO.verifyPayload(options.newBundle, manifest: policy, full: false)
        let source = try readSource(options.sourceStorage)
        guard samePolicy(source.package.manifest, oldPolicy) else { throw Failure.policy }
        let sameStorage = options.sourceStorage.path == options.targetStorage.path
        var targetSource: Source?
        if !sameStorage {
            try RuntimePackageIO.validateAncestors(options.targetStorage.deletingLastPathComponent())
            var metadata = stat()
            if lstat(options.targetStorage.path, &metadata) == 0 {
                let names = try FileManager.default.contentsOfDirectory(atPath: options.targetStorage.path)
                if !names.isEmpty {
                    let existing = try readSource(options.targetStorage)
                    guard existing.stateBytes == source.stateBytes, existing.manifestBytes == source.manifestBytes,
                          existing.signatureBytes == source.signatureBytes, existing.receiptBytes == source.receiptBytes else {
                        throw Failure.target
                    }
                    targetSource = existing
                } else {
                    guard (metadata.st_mode & S_IFMT) == S_IFDIR, metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o700 else {
                        throw Failure.target
                    }
                }
            } else if errno != ENOENT { throw Failure.target }
        }
        let store = RuntimePackageStore(bundleContents: options.newBundle, storageRoot: options.targetStorage)
        let before = try store.snapshot()
        // The old compatibility failure is the explicit subject of migration;
        // no old package is selected for normal execution through the store.
        if before.pending != nil { throw Failure.target }
        try healthCheck(options.newBundle, source.contents)
        try assertSourceMetadata(source, storage: options.sourceStorage, includingState: true)
        if let targetSource { try assertSourceMetadata(targetSource, storage: options.targetStorage, includingState: true) }
        let checkedTargetSource = targetSource
        let p = source.provenance
        let authorization = try LocalRuntimeBuildProvenance(validatedContents: source.contents,
            validatedManifest: source.package.manifest, sdkArchiveSHA256: p.sdkArchiveSHA256,
            cliSHA256: p.cliSHA256, cliManifestSHA256: p.cliManifestSHA256,
            cliSigningKeySHA256: p.cliSigningKeySHA256, builderRecipeSHA256: p.builderRecipeSHA256)
        let imported = try store.importLocalBuild(at: source.contents, provenance: authorization,
            shouldCancel: { false }, progress: { _ in }, beforeCommit: {
                try assertSourceMetadata(source, storage: options.sourceStorage, includingState: true)
                if let checkedTargetSource { try assertSourceMetadata(checkedTargetSource, storage: options.targetStorage, includingState: true) }
            })
        guard imported.id != source.id else { throw Failure.readback }
        try store.activatePending()
        let restarted = RuntimePackageStore(bundleContents: options.newBundle, storageRoot: options.targetStorage)
        let snapshot = try restarted.snapshot()
        guard try snapshot == store.snapshot(), snapshot.current == imported, snapshot.pending == nil,
              snapshot.previous?.id == before.current.id,
              try restarted.resolvedRuntimeRoot().path == options.targetStorage.appendingPathComponent("local-versions/" + imported.id + "/Contents").path else {
            throw Failure.readback
        }
        let next = try readSource(options.targetStorage)
        guard next.package.manifest.files == source.package.manifest.files,
              next.provenance == source.provenance,
              samePolicy(next.package.manifest, policy) else { throw Failure.readback }
        try assertSourceMetadata(source, storage: options.sourceStorage, includingState: !sameStorage)
        try RuntimePackageIO.verifyPayload(source.contents, manifest: source.package.manifest, full: true,
                                          packageRoot: source.contents.deletingLastPathComponent())
        return ["schema": "local-runtime-reissue/v1", "ok": true, "sourceID": source.id, "newID": imported.id,
                "cliVersion": imported.cliVersion, "sdkVersion": imported.sdkVersion, "nodeVersion": imported.nodeVersion,
                "payloadUnchanged": true, "provenanceUnchanged": true, "oldPackagePreserved": true,
                "activated": true, "restartEqual": true, "sourceStorageUnchanged": !sameStorage,
                "realProviderCalled": false, "previousID": snapshot.previous?.id ?? "bundled"]
    }

    static func parse(_ arguments: [String]) throws -> Options {
        let names = Set(["--old-bundle-contents", "--new-bundle-contents", "--source-storage", "--target-storage", "--node"])
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard names.contains(arguments[index]), index + 1 < arguments.count, values[arguments[index]] == nil else { throw Failure.arguments }
            values[arguments[index]] = arguments[index + 1]; index += 2
        }
        guard Set(values.keys) == names else { throw Failure.arguments }
        func url(_ name: String) throws -> URL {
            guard let value = values[name], value.hasPrefix("/"), value.utf8.count <= 4096,
                  !value.utf8.contains(where: { $0 < 32 || $0 == 127 }),
                  !value.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw Failure.arguments
            }
            return URL(fileURLWithPath: value)
        }
        return try .init(oldBundle: url("--old-bundle-contents"), newBundle: url("--new-bundle-contents"),
                         sourceStorage: url("--source-storage"), targetStorage: url("--target-storage"), node: url("--node"))
    }

    static func runHealth(bundle: URL, contents: URL, node: URL) throws {
        try RuntimePackageIO.validateAncestors(node.deletingLastPathComponent())
        let nodeMetadata = try RuntimePackageIO.statFile(node)
        guard nodeMetadata.st_mode & 0o111 != 0 else { throw Failure.arguments }
        let script = bundle.appendingPathComponent("Resources/Runtime/updates/health.mjs")
        let (manifest, _) = try readBundle(bundle)
        guard let probe = manifest.files.first(where: { $0.path == "Resources/Runtime/updates/health.mjs" }),
              try RuntimePackageIO.streamDigest(script) == probe.sha256 else { throw Failure.health }
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw Failure.cleanup }
        let parent = URL(fileURLWithPath: String(cString: physical)); free(physical)
        let scratch = parent.appendingPathComponent("ClaudeRuntimeReissueHealth-" + UUID().uuidString)
        try RuntimePackageIO.createPrivateDirectory(scratch)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = node; process.arguments = [script.path]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
                               "TZ": "UTC", "HOME": scratch.path, "TMPDIR": scratch.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let request = try JSONSerialization.data(withJSONObject: ["schema": "runtime-update-health/v1", "contentsRoot": contents.path]) + Data([10])
        // The verified probe has its own 90-second deadline and SIGTERM cleanup.
        var operation: Result<Void, Error>
        var inputClosed = false
        do {
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.health }
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: request)
            try input.fileHandleForWriting.close()
            inputClosed = true
            var bytes = Data()
            while let chunk = try output.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                bytes.append(chunk)
                guard bytes.count <= 4096 else { throw Failure.health }
            }
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0,
                  let receipt = try JSONSerialization.jsonObject(with: bytes) as? [String: String],
                  receipt == ["type": "healthy"] else { throw Failure.health }
            operation = .success(())
        } catch { operation = .failure(Failure.health) }
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        if !inputClosed { try input.fileHandleForWriting.close() }
        try output.fileHandleForReading.close()
        // A remaining run directory means cleanup is unconfirmed. Preserve it
        // instead of deleting a potentially live VM's files or committing state.
        guard try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty else { throw Failure.cleanup }
        try FileManager.default.removeItem(at: scratch)
        try operation.get()
    }
}

#if !REISSUE_RUNTIME_TESTING
@main
enum ReissueLocalRuntimeCommand {
    static func main() {
        do {
            let options = try ReissueLocalRuntime.parse(Array(CommandLine.arguments.dropFirst()))
            let result = try ReissueLocalRuntime.execute(options: options) { bundle, contents in
                try ReissueLocalRuntime.runHealth(bundle: bundle, contents: contents, node: options.node)
            }
            let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: bytes, as: UTF8.self))
        } catch {
            let code = (error as? ReissueLocalRuntime.Failure)?.rawValue ?? (error as? RuntimePackageFailure)?.code ?? "REISSUE_FAILED"
            print("{\"schema\":\"local-runtime-reissue/v1\",\"ok\":false,\"code\":\"\(code)\"}")
            exit(1)
        }
    }
}
#endif
