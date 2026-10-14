import Foundation
import Darwin

private struct RuntimePackageState: Codable, Equatable {
    let schema: String
    var current: String?
    var previous: String?
    var pending: String?

    static let empty = RuntimePackageState(schema: "claude-runtime-state/v1", current: nil, previous: nil, pending: nil)
}

final class RuntimePackageStore: LocalRuntimePackageManaging, @unchecked Sendable {
    private let bundleContents: URL
    private let storageRoot: URL
    private let lock = NSLock()
    private var importInProgress = false

    init(bundleContents: URL, storageRoot: URL) {
        self.bundleContents = bundleContents
        self.storageRoot = storageRoot
    }

    private var stateURL: URL { storageRoot.appendingPathComponent("state.json") }
    private var versionsURL: URL { storageRoot.appendingPathComponent("versions", isDirectory: true) }
    private var localVersionsURL: URL { storageRoot.appendingPathComponent("local-versions", isDirectory: true) }
    private var localReceiptsURL: URL { storageRoot.appendingPathComponent("local-receipts", isDirectory: true) }
    private var localTrustURL: URL { storageRoot.appendingPathComponent("local-trust", isDirectory: true) }

    private struct Context {
        let bundled: RuntimePackageVerified
        let trust: RuntimePackageTrust
        let appVersion: String
    }

    private func context() throws -> Context {
        try RuntimePackageIO.validateAncestors(bundleContents)
        let bytes = try RuntimePackageIO.readSmall(bundleContents.appendingPathComponent("Resources/BundledRuntimeManifest.json"),
                                                 limit: RuntimePackageIO.maximumManifestBytes)
        let manifest = try RuntimePackageIO.decodeManifest(bytes)
        let bundled = RuntimePackageVerified(manifest: manifest, bytes: bytes, signatureBytes: nil,
                                             id: "bundled")
        let infoData = try RuntimePackageIO.readSmall(bundleContents.appendingPathComponent("Info.plist"), limit: 128 * 1024)
        let appVersion: String
        do {
            guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
                  let version = info["CFBundleShortVersionString"] as? String,
                  RuntimePackageIO.isVersion(version) else { throw RuntimePackageFailure.incompatible }
            appVersion = version
        } catch { throw RuntimePackageFailure.incompatible }
        try manifest.validateCompatibility(appVersion: appVersion)
        let trust = try RuntimePackageIO.loadTrust(bundleContents.appendingPathComponent("Resources/RuntimeTrust.json"))
        return Context(bundled: bundled, trust: trust, appVersion: appVersion)
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func loadState(_ context: Context) throws -> RuntimePackageState {
        var root = stat()
        if lstat(storageRoot.path, &root) != 0 {
            guard errno == ENOENT else { throw RuntimePackageFailure.invalidState }
            return .empty
        }
        guard (root.st_mode & S_IFMT) == S_IFDIR, root.st_uid == getuid(), root.st_mode & 0o777 == 0o700 else {
            throw RuntimePackageFailure.invalidState
        }
        do { try RuntimePackageIO.validateAncestors(storageRoot) }
        catch { throw RuntimePackageFailure.invalidState }
        var metadata = stat()
        if lstat(stateURL.path, &metadata) != 0 {
            guard errno == ENOENT else { throw RuntimePackageFailure.invalidState }
            return .empty
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_uid == getuid(), metadata.st_nlink == 1,
              metadata.st_mode & 0o777 == 0o600 else { throw RuntimePackageFailure.invalidState }
        do {
            let state = try JSONDecoder().decode(RuntimePackageState.self, from: RuntimePackageIO.readSmall(stateURL, limit: 16 * 1024))
            guard state.schema == RuntimePackageState.empty.schema,
                  [state.current, state.previous, state.pending].compactMap({ $0 }).allSatisfy({ validID($0, context: context) }),
                  state.current != context.bundled.id,
                  state.pending == nil || state.pending != (state.current ?? context.bundled.id),
                  state.previous == nil || state.previous != (state.current ?? context.bundled.id) else {
                throw RuntimePackageFailure.invalidState
            }
            return state
        } catch { throw RuntimePackageFailure.invalidState }
    }

    private func validID(_ id: String, context: Context) -> Bool {
        id == context.bundled.id ||
        (id.hasPrefix("runtime-") && RuntimePackageIO.isDigest(String(id.dropFirst(8)))) ||
        (id.hasPrefix("local-") && RuntimePackageIO.isDigest(String(id.dropFirst(6))))
    }

    private func resolve(_ id: String?, context: Context, verifyPayload: Bool) throws -> (RuntimePackageVerified, URL) {
        if id == nil || id == context.bundled.id {
            if verifyPayload {
                try RuntimePackageIO.verifyPayload(bundleContents, manifest: context.bundled.manifest, full: false)
            }
            return (context.bundled, bundleContents)
        }
        guard let id, validID(id, context: context) else { throw RuntimePackageFailure.invalidState }
        let isLocal = id.hasPrefix("local-")
        let directory = (isLocal ? localVersionsURL : versionsURL).appendingPathComponent(id, isDirectory: true)
        do {
            let metadata = try RuntimePackageIO.statFile(directory, directory: true)
            guard metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o500 else {
                throw RuntimePackageFailure.integrityFailed
            }
            let package: RuntimePackageVerified
            if isLocal {
                let identity = try LocalRuntimePackageIO.loadIdentity(at: localTrustURL)
                package = try LocalRuntimePackageIO.signedManifest(at: directory, identity: identity)
                let provenance = try LocalRuntimePackageIO.verifyReceipt(at: localReceiptsURL.appendingPathComponent(id + ".json"),
                                                                        package: package, identity: identity)
                try LocalRuntimePackageIO.validateProvenancePayload(directory.appendingPathComponent("Contents"),
                                                                    provenance: provenance)
            } else {
                package = try RuntimePackageIO.signedManifest(at: directory, trust: context.trust)
            }
            guard package.id == id else { throw RuntimePackageFailure.integrityFailed }
            try package.manifest.validateCompatibility(appVersion: context.appVersion)
            let contents = directory.appendingPathComponent("Contents", isDirectory: true)
            if verifyPayload {
                try RuntimePackageIO.verifyPayload(contents, manifest: package.manifest, full: false, packageRoot: directory)
            }
            return (package, contents)
        } catch let failure as RuntimePackageFailure { throw failure }
        catch { throw RuntimePackageFailure.integrityFailed }
    }

    func snapshot() throws -> RuntimePackageSnapshot {
        try withLock {
            let context = try self.context()
            let state = try loadState(context)
            // Snapshot reads signed metadata only. Full image hashing belongs to background import;
            // every actual process resolution checks the small executable/bridge files again.
            var diagnostics: [String] = []
            func displayed(_ id: String?, label: String) -> RuntimePackageInfo {
                do { return try resolve(id, context: context, verifyPayload: false).0.info }
                catch {
                    let message = (error as? RuntimePackageFailure)?.message ?? RuntimePackageFailure.integrityFailed.message
                    diagnostics.append(label + "：" + message)
                    // Preserve only the state-validated ID for explicit recovery. Corrupt or unsigned
                    // metadata never contributes a claimed software version to the UI.
                    return .init(id: id ?? context.bundled.id, version: "校验失败", cliVersion: "—", sdkVersion: "—", nodeVersion: "—")
                }
            }
            let current = displayed(state.current, label: "当前运行包")
            let previous = state.previous.map { displayed($0, label: "上一运行包") }
            let pending = state.pending.map { displayed($0, label: "待启用运行包") }
            return .init(bundled: context.bundled.info, current: current, previous: previous, pending: pending,
                         diagnostic: diagnostics.isEmpty ? nil : diagnostics.joined(separator: "\n"))
        }
    }

    func resolvedRuntimeRoot() throws -> URL {
        try withLock {
            let context = try self.context()
            let state = try loadState(context)
            return try resolve(state.current, context: context, verifyPayload: true).1
        }
    }

    private func ensureStorage() throws {
        func createParents(_ directory: URL) throws {
            var metadata = stat()
            if lstat(directory.path, &metadata) == 0 {
                try RuntimePackageIO.validateAncestors(directory)
                return
            }
            guard errno == ENOENT, directory.path != "/" else { throw RuntimePackageFailure.persistenceFailed }
            try createParents(directory.deletingLastPathComponent())
            try RuntimePackageIO.createPrivateDirectory(directory)
        }
        try createParents(storageRoot.deletingLastPathComponent())
        try RuntimePackageIO.createPrivateDirectory(storageRoot)
        try RuntimePackageIO.createPrivateDirectory(versionsURL)
    }

    /// Advisory locks serialize this store's mutations across App instances. Readers use atomic
    /// state snapshots and remain available while an importer hashes/copies the large disk.
    private func acquireMutationLock() throws -> Int32 {
        try ensureStorage()
        let url = storageRoot.appendingPathComponent(".operation.lock")
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RuntimePackageFailure.persistenceFailed }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_nlink == 1, metadata.st_mode & 0o777 == 0o600 else {
            close(fd)
            throw RuntimePackageFailure.persistenceFailed
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            close(fd)
            throw busy ? RuntimePackageFailure.busy : RuntimePackageFailure.persistenceFailed
        }
        return fd
    }

    private func releaseMutationLock(_ fd: Int32) {
        // close also releases flock, including during unwinding or process termination.
        close(fd)
    }

    private func saveState(_ state: RuntimePackageState, context: Context) throws {
        try ensureStorage()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes: Data
        do { bytes = try encoder.encode(state) }
        catch { throw RuntimePackageFailure.persistenceFailed }
        try RuntimePackageIO.atomicWrite(bytes, to: stateURL)
        guard try loadState(context) == state else { throw RuntimePackageFailure.persistenceFailed }
    }

    func importPackage(at url: URL, shouldCancel: @Sendable () -> Bool,
                       progress: @Sendable (Double) -> Void) throws -> RuntimePackageInfo {
        let context: Context = try withLock {
            guard !importInProgress else { throw RuntimePackageFailure.busy }
            let context = try self.context()
            _ = try loadState(context)
            importInProgress = true
            return context
        }
        defer { withLock { importInProgress = false } }
        guard url.isFileURL, url.pathExtension.lowercased() == "clauderuntime" else {
            throw RuntimePackageFailure.invalidPackage
        }
        if shouldCancel() { throw RuntimePackageFailure.cancelled }
        progress(0)
        let package = try RuntimePackageIO.signedManifest(at: url, trust: context.trust)
        try package.manifest.validateCompatibility(appVersion: context.appVersion)
        let sourceContents = url.appendingPathComponent("Contents", isDirectory: true)
        try RuntimePackageIO.verifyPayload(sourceContents, manifest: package.manifest, full: true, packageRoot: url,
                                           shouldCancel: shouldCancel, progress: { progress($0 * 0.4) })
        if shouldCancel() { throw RuntimePackageFailure.cancelled }
        // This milestone separates source validation from copying; neither phase executes payloads.
        progress(0.45)
        let (staging, mutationFD): (URL, Int32) = try withLock {
            let fd = try acquireMutationLock()
            let staging = storageRoot.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
            do { try RuntimePackageIO.createPrivateDirectory(staging) }
            catch { releaseMutationLock(fd); throw error }
            return (staging, fd)
        }
        defer { releaseMutationLock(mutationFD) }
        do {
            try RuntimePackageIO.copyPayload(from: sourceContents, to: staging.appendingPathComponent("Contents", isDirectory: true),
                                             manifest: package.manifest, shouldCancel: shouldCancel,
                                             progress: { progress(0.45 + $0 * 0.1) })
            try RuntimePackageIO.atomicWrite(package.bytes, to: staging.appendingPathComponent("manifest.json"), mode: 0o400)
            guard let signature = package.signatureBytes else { throw RuntimePackageFailure.invalidPackage }
            try RuntimePackageIO.atomicWrite(signature, to: staging.appendingPathComponent("signature.json"), mode: 0o400)
            let copied = try RuntimePackageIO.signedManifest(at: staging, trust: context.trust)
            guard copied.id == package.id else { throw RuntimePackageFailure.integrityFailed }
            try RuntimePackageIO.verifyPayload(staging.appendingPathComponent("Contents"), manifest: copied.manifest,
                                               full: true, packageRoot: staging, shouldCancel: shouldCancel,
                                               progress: { progress(0.55 + $0 * 0.4) })
            if shouldCancel() { throw RuntimePackageFailure.cancelled }
            let destination = versionsURL.appendingPathComponent(package.id, isDirectory: true)
            var existing = stat()
            let alreadyInstalled = lstat(destination.path, &existing) == 0
            if alreadyInstalled {
                let installed = try resolve(package.id, context: context, verifyPayload: false).0
                guard installed.bytes == package.bytes else { throw RuntimePackageFailure.integrityFailed }
                // This can hash a large disk, so it stays outside the state/mutation lock.
                try RuntimePackageIO.verifyPayload(destination.appendingPathComponent("Contents"), manifest: installed.manifest,
                                                   full: true, packageRoot: destination, shouldCancel: shouldCancel)
            } else if errno != ENOENT { throw RuntimePackageFailure.persistenceFailed }
            // macOS needs the source directory writable to update '..' during a move between parents.
            try RuntimePackageIO.sealDirectories(staging, manifest: copied.manifest, sealRoot: false)
            try withLock {
                var state = try loadState(context)
                guard package.id != (state.current ?? context.bundled.id) else { throw RuntimePackageFailure.invalidPackage }
                if alreadyInstalled {
                    // Existing immutable versions are never replaced or deleted. Verify before reuse.
                    let installed = try resolve(package.id, context: context, verifyPayload: false).0
                    guard installed.bytes == package.bytes else { throw RuntimePackageFailure.integrityFailed }
                    try RuntimePackageIO.removeOwnedStaging(staging)
                } else {
                    guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                        throw RuntimePackageFailure.persistenceFailed
                    }
                    guard chmod(destination.path, 0o500) == 0 else { throw RuntimePackageFailure.persistenceFailed }
                    try RuntimePackageIO.syncDirectory(destination)
                    try RuntimePackageIO.syncDirectory(versionsURL)
                }
                state.pending = package.id
                try saveState(state, context: context)
            }
            progress(1)
            return package.info
        } catch {
            do { try RuntimePackageIO.removeOwnedStaging(staging) }
            catch { throw RuntimePackageFailure.persistenceFailed }
            if let failure = error as? RuntimePackageFailure { throw failure }
            throw RuntimePackageFailure.persistenceFailed
        }
    }

    func importLocalBuild(at contents: URL, provenance: LocalRuntimeBuildProvenance,
                          shouldCancel: @Sendable () -> Bool,
                          progress: @Sendable (Double) -> Void,
                          beforeCommit: (@Sendable () throws -> Void)? = nil) throws -> RuntimePackageInfo {
        let context: Context = try withLock {
            guard !importInProgress else { throw RuntimePackageFailure.busy }
            let context = try self.context()
            _ = try loadState(context)
            importInProgress = true
            return context
        }
        defer { withLock { importInProgress = false } }
        guard contents.isFileURL, contents.path == provenance.candidateContents.path else {
            throw RuntimePackageFailure.invalidPackage
        }
        if shouldCancel() { throw RuntimePackageFailure.cancelled }
        progress(0)
        let metadata = provenance.metadata
        try metadata.validate()
        let policy = context.bundled.manifest
        let manifest = RuntimePackageManifest(schema: RuntimePackageManifest.schemaValue,
                            version: metadata.cliVersion, cliVersion: metadata.cliVersion,
                            sdkVersion: metadata.sdkVersion, nodeVersion: metadata.nodeVersion,
                            hostProtocol: policy.hostProtocol, platform: policy.platform,
                            minimumOSVersion: policy.minimumOSVersion,
                            minimumAppVersion: policy.minimumAppVersion,
                            maximumAppVersionExclusive: policy.maximumAppVersionExclusive,
                            files: provenance.expectedFiles)
        try manifest.validate()
        try manifest.validateCompatibility(appVersion: context.appVersion)
        try LocalRuntimePackageIO.validateCandidateRoot(contents)
        try LocalRuntimePackageIO.validateProvenancePayload(contents, provenance: metadata)
        try RuntimePackageIO.verifyPayload(contents, manifest: manifest, full: true,
                                           shouldCancel: shouldCancel, progress: { progress($0 * 0.4) })
        if shouldCancel() { throw RuntimePackageFailure.cancelled }
        progress(0.45)
        let (staging, mutationFD): (URL, Int32) = try withLock {
            let fd = try acquireMutationLock()
            let staging = storageRoot.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
            do { try RuntimePackageIO.createPrivateDirectory(staging) }
            catch { releaseMutationLock(fd); throw error }
            return (staging, fd)
        }
        defer { releaseMutationLock(mutationFD) }
        var newlyWrittenReceipt: URL?
        var committedLocalDirectory = false
        var precommitFailure: Error?
        do {
            try RuntimePackageIO.copyPayload(from: contents, to: staging.appendingPathComponent("Contents", isDirectory: true),
                                             manifest: manifest, shouldCancel: shouldCancel,
                                             progress: { progress(0.45 + $0 * 0.1) })
            try RuntimePackageIO.verifyPayload(staging.appendingPathComponent("Contents"), manifest: manifest,
                                               full: true, shouldCancel: shouldCancel,
                                               progress: { progress(0.55 + $0 * 0.4) })
            try LocalRuntimePackageIO.validateProvenancePayload(staging.appendingPathComponent("Contents"), provenance: metadata)
            if shouldCancel() { throw RuntimePackageFailure.cancelled }
            // Key creation occurs only after the copied payload has passed all checks. It never
            // authorizes external imports and never changes the bundled publisher trust file.
            try RuntimePackageIO.createPrivateDirectory(localVersionsURL)
            try RuntimePackageIO.createPrivateDirectory(localReceiptsURL)
            let identity = try LocalRuntimePackageIO.loadIdentity(at: localTrustURL, create: true)
            let package = try LocalRuntimePackageIO.signManifest(manifest, identity: identity)
            let receipt = try LocalRuntimePackageIO.signedReceipt(for: package, provenance: metadata, identity: identity)
            try RuntimePackageIO.atomicWrite(package.bytes, to: staging.appendingPathComponent("manifest.json"), mode: 0o400)
            guard let signature = package.signatureBytes else { throw RuntimePackageFailure.integrityFailed }
            try RuntimePackageIO.atomicWrite(signature, to: staging.appendingPathComponent("signature.json"), mode: 0o400)
            let copied = try LocalRuntimePackageIO.signedManifest(at: staging, identity: identity)
            guard copied.id == package.id else { throw RuntimePackageFailure.integrityFailed }
            try RuntimePackageIO.inventory(staging.appendingPathComponent("Contents"), manifest: copied.manifest, packageRoot: staging)
            let destination = localVersionsURL.appendingPathComponent(package.id, isDirectory: true)
            let receiptURL = localReceiptsURL.appendingPathComponent(package.id + ".json")
            var existing = stat()
            let alreadyInstalled = lstat(destination.path, &existing) == 0
            if alreadyInstalled {
                let installed = try resolve(package.id, context: context, verifyPayload: false).0
                guard installed.bytes == package.bytes,
                      try LocalRuntimePackageIO.verifyReceipt(at: receiptURL, package: installed, identity: identity) == metadata else {
                    throw RuntimePackageFailure.integrityFailed
                }
                try RuntimePackageIO.verifyPayload(destination.appendingPathComponent("Contents"), manifest: installed.manifest,
                                                   full: true, packageRoot: destination, shouldCancel: shouldCancel)
            } else if errno != ENOENT { throw RuntimePackageFailure.persistenceFailed }
            try RuntimePackageIO.sealDirectories(staging, manifest: copied.manifest, sealRoot: false)
            if shouldCancel() { throw RuntimePackageFailure.cancelled }
            // All source bytes, signed metadata, and provenance are now cached or owned by
            // staging. The builder can remove and verify its scratch before pending changes.
            do { try beforeCommit?() }
            catch { precommitFailure = error; throw error }
            try withLock {
                if shouldCancel() { throw RuntimePackageFailure.cancelled }
                var state = try loadState(context)
                guard package.id != (state.current ?? context.bundled.id) else { throw RuntimePackageFailure.invalidPackage }
                if alreadyInstalled {
                    let installed = try resolve(package.id, context: context, verifyPayload: false).0
                    guard installed.bytes == package.bytes else { throw RuntimePackageFailure.integrityFailed }
                    try RuntimePackageIO.removeOwnedStaging(staging)
                } else {
                    // Persist signed provenance first. Once the immutable directory is moved,
                    // an interrupted state write leaves a complete version that can be reused.
                    var priorReceipt = stat()
                    if lstat(receiptURL.path, &priorReceipt) == 0 {
                        guard try LocalRuntimePackageIO.verifyReceipt(at: receiptURL, package: package, identity: identity) == metadata else {
                            throw RuntimePackageFailure.integrityFailed
                        }
                    } else {
                        guard errno == ENOENT else { throw RuntimePackageFailure.persistenceFailed }
                        try RuntimePackageIO.atomicWrite(receipt, to: receiptURL, mode: 0o400)
                        newlyWrittenReceipt = receiptURL
                        try LocalRuntimePackageIO.verifyReceipt(at: receiptURL, package: package, identity: identity)
                    }
                    guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                        throw RuntimePackageFailure.persistenceFailed
                    }
                    committedLocalDirectory = true
                    guard chmod(destination.path, 0o500) == 0 else { throw RuntimePackageFailure.persistenceFailed }
                    try RuntimePackageIO.syncDirectory(destination)
                    try RuntimePackageIO.syncDirectory(localVersionsURL)
                }
                state.pending = package.id
                try saveState(state, context: context)
            }
            progress(1)
            return package.info
        } catch {
            do { try RuntimePackageIO.removeOwnedStaging(staging) }
            catch { throw RuntimePackageFailure.persistenceFailed }
            if let receipt = newlyWrittenReceipt, !committedLocalDirectory {
                guard unlink(receipt.path) == 0 else { throw RuntimePackageFailure.persistenceFailed }
                try RuntimePackageIO.syncDirectory(localReceiptsURL)
            }
            if let precommitFailure { throw precommitFailure }
            if let failure = error as? RuntimePackageFailure { throw failure }
            throw RuntimePackageFailure.persistenceFailed
        }
    }

    func requestRollback() throws {
        try withLock {
            guard !importInProgress else { throw RuntimePackageFailure.busy }
            let context = try context()
            let fd = try acquireMutationLock()
            defer { releaseMutationLock(fd) }
            var state = try loadState(context)
            guard let previous = state.previous else { throw RuntimePackageFailure.noPrevious }
            _ = try resolve(previous, context: context, verifyPayload: true)
            state.pending = previous
            try saveState(state, context: context)
        }
    }

    func activatePending() throws {
        try withLock {
            guard !importInProgress else { throw RuntimePackageFailure.busy }
            let context = try context()
            let fd = try acquireMutationLock()
            defer { releaseMutationLock(fd) }
            var state = try loadState(context)
            guard let pending = state.pending else { throw RuntimePackageFailure.noPending }
            _ = try resolve(pending, context: context, verifyPayload: true)
            // A corrupt current version is not silently substituted. Explicit rollback still validates
            // the selected previous version, while preserving the old ID for diagnosis/reversal.
            state.previous = state.current ?? context.bundled.id
            state.current = pending == context.bundled.id ? nil : pending
            state.pending = nil
            try saveState(state, context: context)
        }
    }

    func cancelPending() throws {
        try withLock {
            guard !importInProgress else { throw RuntimePackageFailure.busy }
            let context = try context()
            let fd = try acquireMutationLock()
            defer { releaseMutationLock(fd) }
            var state = try loadState(context)
            state.pending = nil
            try saveState(state, context: context)
        }
    }
}
