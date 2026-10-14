import CoreFoundation
import CryptoKit
import Darwin
import Foundation

enum RuntimeUpdateFailure: Error, LocalizedError, Equatable, Sendable {
    case invalidSource, sourceUnavailable, transportMissing, networkUnavailable, invalidResponse
    case untrustedSigner, integrityFailed, incompatible, timeout, cancelled
    case downloadFailed, healthFailed, persistenceFailed, cleanupFailed

    var code: String {
        switch self {
        case .invalidSource: "UPDATE_INVALID_FEED"
        case .sourceUnavailable: "UPDATE_SOURCE_UNAVAILABLE"
        case .transportMissing: "UPDATE_BRIDGE_MISSING"
        case .networkUnavailable: "UPDATE_NETWORK_FAILED"
        case .invalidResponse: "UPDATE_METADATA_INVALID"
        case .untrustedSigner: "UPDATE_UNTRUSTED_SIGNER"
        case .integrityFailed: "UPDATE_INTEGRITY_FAILED"
        case .incompatible: "UPDATE_INCOMPATIBLE"
        case .timeout: "UPDATE_TIMEOUT"
        case .cancelled: "UPDATE_CANCELLED"
        case .downloadFailed: "UPDATE_DOWNLOAD_FAILED"
        case .healthFailed: "UPDATE_HEALTH_FAILED"
        case .persistenceFailed: "UPDATE_SAVE_FAILED"
        case .cleanupFailed: "UPDATE_CLEANUP_FAILED"
        }
    }

    var message: String {
        switch self {
        case .invalidSource: "更新源无效。请填写以 /channel.json 结尾的 HTTPS 地址，不包含账号、密码、查询参数或空白。"
        case .sourceUnavailable: "更新源暂时不可用，尚未取得最新版本信息。请检查发布服务后重试。"
        case .transportMissing: "App 的更新组件不可用，请重新安装完整的 App。"
        case .networkUnavailable: "无法通过已保存的统一代理连接更新源，请检查网络设置后重试。"
        case .invalidResponse: "更新源返回的数据未通过格式校验，尚未取得可用的新版本。"
        case .untrustedSigner: "更新发布者未获得当前 App 信任，已阻止下载或使用。"
        case .integrityFailed: "更新签名或文件摘要不一致，已阻止使用该版本。"
        case .incompatible: "更新版本与当前 App、处理器或 macOS 版本不兼容，请使用兼容的发布版本。"
        case .timeout: "更新操作超时，请检查网络或本机运行环境后重试。"
        case .cancelled: "已取消在线更新，当前运行版本保持不变。"
        case .downloadFailed: "运行包下载未完成，当前运行版本保持不变。请检查更新源后重试。"
        case .healthFailed: "候选运行包未通过本机健康检查，未加入待启用版本。请联系发布者提供有效运行包。"
        case .persistenceFailed: "更新配置或运行包未能安全保存，请检查可用磁盘空间后重试。"
        case .cleanupFailed: "更新临时目录未能确认清理，请检查 App 的临时目录权限后重试。"
        }
    }

    var errorDescription: String? { message }

    static func fromPackage(_ failure: RuntimePackageFailure) -> RuntimeUpdateFailure {
        switch failure {
        case .untrustedSigner: .untrustedSigner
        case .integrityFailed: .integrityFailed
        case .incompatible: .incompatible
        case .cancelled: .cancelled
        case .persistenceFailed: .persistenceFailed
        default: .invalidResponse
        }
    }

    fileprivate static func fromWire(_ code: String, operation: RuntimeUpdateOperation) throws -> RuntimeUpdateFailure {
        switch code {
        case "UPDATE_INVALID_FEED": return .invalidSource
        case "UPDATE_NETWORK_POLICY_INVALID", "UPDATE_NETWORK_FAILED": return .networkUnavailable
        case "UPDATE_REDIRECT_REFUSED", "UPDATE_HTTP_FAILED":
            return operation == .download ? .downloadFailed : .sourceUnavailable
        case "UPDATE_DOWNLOAD_SIZE", "UPDATE_DOWNLOAD_HASH": return .integrityFailed
        case "UPDATE_DOWNLOAD_INVALID": return .downloadFailed
        case "UPDATE_SAVE_FAILED", "UPDATE_STAGING_INVALID": return .persistenceFailed
        case "UPDATE_CANCELLED": return .cancelled
        case "UPDATE_INPUT_TIMEOUT": return .timeout
        case "UPDATE_HEALTH_FAILED": return .healthFailed
        case "UPDATE_INVALID_REQUEST", "UPDATE_METADATA_TOO_LARGE", "UPDATE_METADATA_INVALID",
             "UPDATE_PACKAGE_INVALID", "UPDATE_INPUT_TOO_LARGE": return .invalidResponse
        default: throw RuntimeUpdateFailure.invalidResponse
        }
    }
}

struct RuntimeUpdateRelease: Sendable {
    let feedURL: URL
    let manifest: RuntimePackageManifest
    let manifestBytes: Data
    let signatureBytes: Data
    let id: String
    let info: RuntimePackageInfo
    let totalBytes: Int64
}

protocol RuntimeUpdating: Sendable {
    func check(feedURL: URL, current: RuntimePackageInfo, controller: OwnedProcessController) throws -> RuntimeUpdateRelease?
    func prepareAndImport(_ release: RuntimeUpdateRelease, store: any RuntimePackageManaging,
                          controller: OwnedProcessController,
                          progress: @Sendable (Double, String) -> Void) throws -> RuntimePackageInfo
}

enum RuntimeUpdateChannel {
    static let schemaValue = "claude-runtime-channel/v1"
    static let maximumBytes = 3 * 1024 * 1024

    /// No manifest field is decoded or used until the exact published bytes have a valid signature.
    static func verify(_ data: Data, trust: RuntimePackageTrust, appVersion: String) throws -> RuntimePackageVerified {
        guard !data.isEmpty, data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schema", "manifestBase64", "signatureBase64"]),
              object["schema"] as? String == schemaValue,
              let manifestBase64 = object["manifestBase64"] as? String,
              let signatureBase64 = object["signatureBase64"] as? String,
              let manifestBytes = Data(base64Encoded: manifestBase64),
              let signatureBytes = Data(base64Encoded: signatureBase64) else {
            throw RuntimeUpdateFailure.invalidResponse
        }
        return try verifyManifest(manifestBytes, signatureBytes: signatureBytes, trust: trust, appVersion: appVersion)
    }

    static func verifyManifest(_ bytes: Data, signatureBytes: Data, trust: RuntimePackageTrust,
                               appVersion: String) throws -> RuntimePackageVerified {
        guard !bytes.isEmpty, bytes.count <= RuntimePackageIO.maximumManifestBytes,
              !signatureBytes.isEmpty, signatureBytes.count <= 4_096,
              let object = try? JSONSerialization.jsonObject(with: signatureBytes) as? [String: Any],
              Set(object.keys) == Set(["schema", "keyID", "signature"]),
              object["schema"] as? String == RuntimePackageSignature.schemaValue,
              let keyID = object["keyID"] as? String,
              let encodedSignature = object["signature"] as? String,
              let signature = Data(base64Encoded: encodedSignature), signature.count == 64 else {
            throw RuntimeUpdateFailure.invalidResponse
        }
        guard trust.schema == RuntimePackageTrust.schemaValue,
              let encodedKey = trust.publicKeys[keyID], let rawKey = Data(base64Encoded: encodedKey),
              rawKey.count == 32, RuntimePackageIO.digest(rawKey) == keyID,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else {
            throw RuntimeUpdateFailure.untrustedSigner
        }
        guard key.isValidSignature(signature, for: bytes) else { throw RuntimeUpdateFailure.integrityFailed }
        let manifest: RuntimePackageManifest
        do {
            manifest = try RuntimePackageIO.decodeManifest(bytes)
            try manifest.validateCompatibility(appVersion: appVersion)
        } catch let failure as RuntimePackageFailure { throw RuntimeUpdateFailure.fromPackage(failure) }
        catch { throw RuntimeUpdateFailure.invalidResponse }
        return .init(manifest: manifest, bytes: bytes, signatureBytes: signatureBytes,
                     id: "runtime-" + RuntimePackageIO.digest(bytes))
    }
}

struct StdioRuntimeUpdateService: RuntimeUpdating {
    let configuration: AppConfiguration
    let bundleContents: URL
    var networkPolicyProvider: any NetworkPolicyProviding = SavedNetworkPolicyProvider()

    static func checkChannel(_ data: Data, feedURL: URL, current: RuntimePackageInfo,
                             trust: RuntimePackageTrust, appVersion: String) throws -> RuntimeUpdateRelease? {
        try RuntimeUpdateConfiguration.validateFeedURL(feedURL)
        guard RuntimePackageIO.isVersion(current.version) else { throw RuntimeUpdateFailure.invalidResponse }
        let verified = try RuntimeUpdateChannel.verify(data, trust: trust, appVersion: appVersion)
        guard RuntimePackageIO.compareVersion(verified.manifest.version, current.version) > 0 else { return nil }
        guard let signatureBytes = verified.signatureBytes else { throw RuntimeUpdateFailure.invalidResponse }
        return .init(feedURL: feedURL, manifest: verified.manifest, manifestBytes: verified.bytes,
                     signatureBytes: signatureBytes, id: verified.id, info: verified.info,
                     totalBytes: verified.manifest.files.reduce(Int64(0)) { $0 + $1.size })
    }

    func check(feedURL: URL, current: RuntimePackageInfo, controller: OwnedProcessController) throws -> RuntimeUpdateRelease? {
        try RuntimeUpdateConfiguration.validateFeedURL(feedURL)
        try checkCancellation(controller)
        let context = try trustedContext()
        let network = try networkObject()
        return try withScratchDirectory { scratch in
            let response = try execute(operation: .check, request: [
                "schema": "runtime-update-request/v1", "operation": "check",
                "feedURL": feedURL.absoluteString, "network": network
            ], scratch: scratch, controller: controller)
            guard let channel = response else { throw RuntimeUpdateFailure.invalidResponse }
            try checkCancellation(controller)
            return try Self.checkChannel(channel, feedURL: feedURL, current: current,
                                         trust: context.trust, appVersion: context.appVersion)
        }
    }

    func prepareAndImport(_ release: RuntimeUpdateRelease, store: any RuntimePackageManaging,
                          controller: OwnedProcessController,
                          progress: @Sendable (Double, String) -> Void) throws -> RuntimePackageInfo {
        try RuntimeUpdateConfiguration.validateFeedURL(release.feedURL)
        try checkCancellation(controller)
        let context = try trustedContext()
        let verified = try RuntimeUpdateChannel.verifyManifest(release.manifestBytes,
            signatureBytes: release.signatureBytes, trust: context.trust, appVersion: context.appVersion)
        guard verified.manifest == release.manifest, verified.id == release.id, verified.info == release.info,
              release.totalBytes == verified.manifest.files.reduce(Int64(0), { $0 + $1.size }) else {
            throw RuntimeUpdateFailure.invalidResponse
        }
        let network = try networkObject()
        return try withoutActuallyEscaping(progress) { escapedProgress in
          let reporter = RuntimeUpdateProgressReporter(escapedProgress)
          return try withScratchDirectory { scratch in
            let package = scratch.appendingPathComponent("candidate.clauderuntime", isDirectory: true)
            reporter.emit(0, phase: "download")
            _ = try execute(operation: .download, request: [
                "schema": "runtime-update-request/v1", "operation": "download",
                "feedURL": release.feedURL.absoluteString,
                "manifestBase64": release.manifestBytes.base64EncodedString(),
                "signatureBase64": release.signatureBytes.base64EncodedString(),
                "packageDirectory": package.path, "network": network
            ], scratch: scratch, controller: controller, progress: { value in
                reporter.emit(value * 0.60, phase: "download")
            })
            try checkCancellation(controller)
            reporter.emit(0.60, phase: "verify")
            let downloaded: RuntimePackageVerified
            do {
                downloaded = try RuntimePackageIO.signedManifest(at: package, trust: context.trust)
                guard downloaded.bytes == release.manifestBytes, downloaded.signatureBytes == release.signatureBytes,
                      downloaded.id == release.id else { throw RuntimeUpdateFailure.integrityFailed }
                try downloaded.manifest.validateCompatibility(appVersion: context.appVersion)
                try RuntimePackageIO.verifyPayload(package.appendingPathComponent("Contents", isDirectory: true),
                    manifest: downloaded.manifest, full: true, packageRoot: package,
                    shouldCancel: { controller.isCancelled }, progress: { value in
                        reporter.emit(0.60 + value * 0.20, phase: "verify")
                    })
            } catch let failure as RuntimePackageFailure { throw RuntimeUpdateFailure.fromPackage(failure) }
            try checkCancellation(controller)
            reporter.emit(0.80, phase: "health")
            _ = try execute(operation: .health, request: [
                "schema": "runtime-update-health/v1",
                "contentsRoot": package.appendingPathComponent("Contents", isDirectory: true).path
            ], scratch: scratch, controller: controller)
            try checkCancellation(controller)
            reporter.emit(0.85, phase: "install")
            let installed: RuntimePackageInfo
            do {
                installed = try store.importPackage(at: package, shouldCancel: { controller.isCancelled }, progress: { value in
                    reporter.emit(0.85 + value * 0.15, phase: "install")
                })
            } catch let failure as RuntimePackageFailure { throw RuntimeUpdateFailure.fromPackage(failure) }
            guard installed == release.info else { throw RuntimeUpdateFailure.integrityFailed }
            reporter.emit(1, phase: "install")
            return installed
          }
        }
    }

    private func trustedContext() throws -> (trust: RuntimePackageTrust, appVersion: String) {
        do {
            try RuntimePackageIO.validateAncestors(bundleContents)
            let trust = try RuntimePackageIO.loadTrust(bundleContents.appendingPathComponent("Resources/RuntimeTrust.json"))
            let bytes = try RuntimePackageIO.readSmall(bundleContents.appendingPathComponent("Info.plist"), limit: 128 * 1024)
            guard let info = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                  let version = info["CFBundleShortVersionString"] as? String,
                  RuntimePackageIO.isVersion(version) else { throw RuntimeUpdateFailure.incompatible }
            return (trust, version)
        } catch let failure as RuntimeUpdateFailure { throw failure }
        catch let failure as RuntimePackageFailure { throw RuntimeUpdateFailure.fromPackage(failure) }
        catch { throw RuntimeUpdateFailure.transportMissing }
    }

    private func networkObject() throws -> Any {
        do {
            let policy = try networkPolicyProvider.snapshot()
            try policy.validate()
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy))
        } catch { throw RuntimeUpdateFailure.networkUnavailable }
    }

    private func checkCancellation(_ controller: OwnedProcessController) throws {
        if controller.isTimedOut { throw RuntimeUpdateFailure.timeout }
        if controller.isCancelled { throw RuntimeUpdateFailure.cancelled }
    }

    /// Root registration remains active across all child processes and file verification.
    private func execute(operation: RuntimeUpdateOperation, request: [String: Any], scratch: URL,
                         controller: OwnedProcessController,
                         progress: (Double) -> Void = { _ in }) throws -> Data? {
        try checkCancellation(controller)
        let root = URL(fileURLWithPath: configuration.projectRoot, isDirectory: true)
        let script = root.appendingPathComponent(operation == .health ? "updates/health.mjs" : "updates/stdio.mjs")
        guard configuration.projectRoot.hasPrefix("/"), configuration.nodeExecutable.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: configuration.nodeExecutable) else {
            throw RuntimeUpdateFailure.transportMissing
        }
        do {
            try RuntimePackageIO.validateAncestors(script.deletingLastPathComponent())
            _ = try RuntimePackageIO.statFile(script)
        } catch { throw RuntimeUpdateFailure.transportMissing }
        let payload: Data
        do { payload = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) + Data([10]) }
        catch { throw RuntimeUpdateFailure.invalidResponse }
        guard payload.count <= 4 * 1024 * 1024 else { throw RuntimeUpdateFailure.invalidResponse }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: configuration.nodeExecutable)
        process.arguments = [script.path]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        var environment = AppRuntimeProfile.japan.processEnvironment
        environment["HOME"] = scratch.path
        environment["TMPDIR"] = scratch.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let timeout = DispatchWorkItem { if process.isRunning { controller.cancel(timedOut: true) } }
        var started = false
        var inputClosed = false
        var outcome: Result<Data?, Error>
        do {
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                throw RuntimeUpdateFailure.transportMissing
            }
            try controller.install(process)
            try process.run()
            started = true
            controller.didStart()
            DispatchQueue.global().asyncAfter(deadline: .now() + operation.timeout, execute: timeout)
            try checkCancellation(controller)
            try input.fileHandleForWriting.write(contentsOf: payload)
            try input.fileHandleForWriting.close()
            inputClosed = true
            var parser = RuntimeUpdateResponseParser(operation: operation)
            var pending = Data()
            var outputBytes = 0
            var buffer = [UInt8](repeating: 0, count: 32_768)
            while true {
                try checkCancellation(controller)
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw RuntimeUpdateFailure.invalidResponse
                }
                if count == 0 { break }
                outputBytes += count
                guard outputBytes <= operation.maximumOutputBytes else { throw RuntimeUpdateFailure.invalidResponse }
                pending.append(contentsOf: buffer.prefix(count))
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    guard line.count <= operation.maximumLineBytes, !line.isEmpty else { throw RuntimeUpdateFailure.invalidResponse }
                    if let fraction = try parser.consume(line) { progress(fraction) }
                }
                guard pending.count <= operation.maximumLineBytes else { throw RuntimeUpdateFailure.invalidResponse }
            }
            guard pending.isEmpty else { throw RuntimeUpdateFailure.invalidResponse }
            process.waitUntilExit()
            try checkCancellation(controller)
            outcome = .success(try parser.finish(processSucceeded: process.terminationReason == .exit && process.terminationStatus == 0))
        } catch { outcome = .failure(error) }
        timeout.cancel()
        if started && process.isRunning {
            controller.terminateForCleanup()
            process.waitUntilExit()
        }
        do {
            if !inputClosed { try input.fileHandleForWriting.close() }
            try output.fileHandleForReading.close()
            try controller.clearFinishedProcess(process)
        } catch {
            // Preserve the actionable protocol/cancellation failure if cleanup also fails.
            if case .success = outcome { outcome = .failure(RuntimeUpdateFailure.transportMissing) }
        }
        try checkCancellation(controller)
        do { return try outcome.get() }
        catch let failure as RuntimeUpdateFailure { throw failure }
        catch {
            switch operation {
            case .check: throw RuntimeUpdateFailure.sourceUnavailable
            case .download: throw RuntimeUpdateFailure.downloadFailed
            case .health: throw RuntimeUpdateFailure.healthFailed
            }
        }
    }

    private func withScratchDirectory<T>(_ operation: (URL) throws -> T) throws -> T {
        // Foundation can retain the /var alias even after resolvingSymlinksInPath.
        // The package verifier requires the actual physical ancestor chain.
        guard let physicalPath = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw RuntimeUpdateFailure.persistenceFailed
        }
        let parent = URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
        free(physicalPath)
        let scratch = parent.appendingPathComponent("ClaudeRuntimeUpdate-" + UUID().uuidString, isDirectory: true)
        let identity: stat
        do {
            try RuntimePackageIO.validateAncestors(parent)
            try RuntimePackageIO.createPrivateDirectory(scratch)
            identity = try RuntimePackageIO.statFile(scratch, directory: true)
            guard identity.st_uid == getuid(), identity.st_mode & 0o777 == 0o700 else {
                throw RuntimeUpdateFailure.persistenceFailed
            }
        } catch { throw RuntimeUpdateFailure.persistenceFailed }
        let outcome: Result<T, Error>
        do { outcome = .success(try operation(scratch)) }
        catch { outcome = .failure(error) }
        do {
            try RuntimePackageIO.validateAncestors(scratch)
            let current = try RuntimePackageIO.statFile(scratch, directory: true)
            guard current.st_dev == identity.st_dev, current.st_ino == identity.st_ino,
                  current.st_uid == identity.st_uid, current.st_mode & 0o777 == 0o700 else {
                throw RuntimeUpdateFailure.cleanupFailed
            }
            try FileManager.default.removeItem(at: scratch)
            var remaining = stat()
            guard lstat(scratch.path, &remaining) != 0, errno == ENOENT else { throw RuntimeUpdateFailure.cleanupFailed }
        } catch { throw RuntimeUpdateFailure.cleanupFailed }
        return try outcome.get()
    }
}

fileprivate enum RuntimeUpdateOperation {
    case check, download, health
    var timeout: Double {
        switch self {
        case .check: 45
        case .download: 30 * 60
        case .health: 90
        }
    }
    var maximumLineBytes: Int { self == .check ? 5 * 1024 * 1024 : 4_096 }
    var maximumOutputBytes: Int { self == .check ? 6 * 1024 * 1024 : 128 * 1024 }
}

private struct RuntimeUpdateResponseParser {
    let operation: RuntimeUpdateOperation
    private var terminal: Bool = false
    private var channel: Data?
    private var failure: RuntimeUpdateFailure?
    private var fraction = -1.0
    private var progressCount = 0

    init(operation: RuntimeUpdateOperation) { self.operation = operation }

    mutating func consume(_ line: Data) throws -> Double? {
        guard !terminal, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { throw RuntimeUpdateFailure.invalidResponse }
        switch type {
        case "checked":
            guard operation == .check, Set(object.keys) == Set(["type", "channelBase64"]),
                  let encoded = object["channelBase64"] as? String, let data = Data(base64Encoded: encoded),
                  !data.isEmpty, data.count <= RuntimeUpdateChannel.maximumBytes else {
                throw RuntimeUpdateFailure.invalidResponse
            }
            channel = data
            terminal = true
        case "downloaded":
            guard operation == .download, Set(object.keys) == Set(["type"]) else {
                throw RuntimeUpdateFailure.invalidResponse
            }
            terminal = true
        case "healthy":
            guard operation == .health, Set(object.keys) == Set(["type"]) else {
                throw RuntimeUpdateFailure.invalidResponse
            }
            terminal = true
        case "error":
            guard Set(object.keys) == Set(["type", "code"]), let code = object["code"] as? String else {
                throw RuntimeUpdateFailure.invalidResponse
            }
            failure = try RuntimeUpdateFailure.fromWire(code, operation: operation)
            terminal = true
        case "progress":
            guard operation == .download, Set(object.keys) == Set(["type", "fraction", "phase"]),
                  object["phase"] as? String == "download", let number = object["fraction"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  (0...1).contains(number.doubleValue), number.doubleValue >= fraction,
                  progressCount < 1_002 else { throw RuntimeUpdateFailure.invalidResponse }
            fraction = number.doubleValue
            progressCount += 1
            return fraction
        default: throw RuntimeUpdateFailure.invalidResponse
        }
        return nil
    }

    func finish(processSucceeded: Bool) throws -> Data? {
        guard terminal else { throw RuntimeUpdateFailure.invalidResponse }
        if let failure {
            guard !processSucceeded else { throw RuntimeUpdateFailure.invalidResponse }
            throw failure
        }
        guard processSucceeded else {
            switch operation {
            case .check: throw RuntimeUpdateFailure.sourceUnavailable
            case .download: throw RuntimeUpdateFailure.downloadFailed
            case .health: throw RuntimeUpdateFailure.healthFailed
            }
        }
        return channel
    }
}

private final class RuntimeUpdateProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: @Sendable (Double, String) -> Void
    private var lastFraction = -1.0
    private var lastPhase = ""
    private var lastTime: TimeInterval = 0
    init(_ sink: @escaping @Sendable (Double, String) -> Void) { self.sink = sink }

    func emit(_ value: Double, phase: String) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let fraction = min(1, max(lastFraction, value))
        let shouldEmit = phase != lastPhase || fraction == 1 || now - lastTime >= 0.20
        if shouldEmit {
            lastFraction = fraction
            lastPhase = phase
            lastTime = now
        }
        lock.unlock()
        if shouldEmit { sink(fraction, phase) }
    }
}
