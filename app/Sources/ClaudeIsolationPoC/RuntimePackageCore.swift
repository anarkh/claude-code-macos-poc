import Foundation
import CryptoKit
import Darwin

struct RuntimePackageInfo: Codable, Equatable, Sendable {
    let id: String
    let version: String
    let cliVersion: String
    let sdkVersion: String
    let nodeVersion: String
}

struct RuntimePackageSnapshot: Equatable, Sendable {
    let bundled: RuntimePackageInfo
    let current: RuntimePackageInfo
    let previous: RuntimePackageInfo?
    let pending: RuntimePackageInfo?
    let diagnostic: String?

    init(bundled: RuntimePackageInfo, current: RuntimePackageInfo, previous: RuntimePackageInfo?,
         pending: RuntimePackageInfo?, diagnostic: String? = nil) {
        self.bundled = bundled
        self.current = current
        self.previous = previous
        self.pending = pending
        self.diagnostic = diagnostic
    }
}

protocol RuntimePackageManaging: Sendable {
    func snapshot() throws -> RuntimePackageSnapshot
    func importPackage(at: URL, shouldCancel: @Sendable () -> Bool,
                       progress: @Sendable (Double) -> Void) throws -> RuntimePackageInfo
    func requestRollback() throws
    func activatePending() throws
    func cancelPending() throws
    /// Returns a Contents directory, preserving the signed Runtime/Helpers relative layout.
    func resolvedRuntimeRoot() throws -> URL
}

enum RuntimePackageFailure: Error, LocalizedError, Equatable, Sendable {
    case invalidPackage, untrustedSigner, integrityFailed, incompatible, cancelled, busy
    case persistenceFailed, noPrevious, noPending, invalidState

    var code: String {
        switch self {
        case .invalidPackage: "RUNTIME_PACKAGE_INVALID"
        case .untrustedSigner: "RUNTIME_PACKAGE_UNTRUSTED"
        case .integrityFailed: "RUNTIME_PACKAGE_INTEGRITY"
        case .incompatible: "RUNTIME_PACKAGE_INCOMPATIBLE"
        case .cancelled: "RUNTIME_PACKAGE_CANCELLED"
        case .busy: "RUNTIME_PACKAGE_BUSY"
        case .persistenceFailed: "RUNTIME_PACKAGE_SAVE_FAILED"
        case .noPrevious: "RUNTIME_PACKAGE_NO_PREVIOUS"
        case .noPending: "RUNTIME_PACKAGE_NO_PENDING"
        case .invalidState: "RUNTIME_PACKAGE_STATE_INVALID"
        }
    }

    var message: String {
        switch self {
        case .invalidPackage: "运行时包格式无效，或包含未允许的文件。请重新选择完整的 .clauderuntime 文件夹。"
        case .untrustedSigner: "此运行时包的签名发布者未获得当前 App 信任。请使用当前 App 支持的发布者。"
        case .integrityFailed: "运行时文件与签名清单不一致，已阻止使用。请重新导入完整包。"
        case .incompatible: "此运行时包与当前 App、处理器或 macOS 版本不兼容。"
        case .cancelled: "已取消导入运行时包。"
        case .busy: "正在导入运行时包，请等待完成或取消后再操作。"
        case .persistenceFailed: "运行时包或版本状态未能安全保存，请检查可用磁盘空间后重试。"
        case .noPrevious: "尚无可回滚的上一版本。"
        case .noPending: "没有待应用的运行时版本。"
        case .invalidState: "运行时版本状态损坏，已阻止启动。请修复本地版本状态后再试。"
        }
    }

    var errorDescription: String? { message }
}

struct RuntimePackageFile: Codable, Equatable, Sendable {
    let path: String
    let size: Int64
    let sha256: String
    let executable: Bool
}

struct RuntimePackageManifest: Codable, Equatable, Sendable {
    let schema: String
    let version: String
    let cliVersion: String
    let sdkVersion: String
    let nodeVersion: String
    let hostProtocol: Int
    let platform: String
    let minimumOSVersion: String
    let minimumAppVersion: String
    let maximumAppVersionExclusive: String
    let files: [RuntimePackageFile]

    static let schemaValue = "claude-runtime-package/v1"
    static let diskPath = "Resources/Runtime/host/text-runtime/images/guest.raw"
    static let requiredPaths: Set<String> = Set([
        "Helpers/vm-text-runtime",
        "Resources/Runtime/sdk/vm-text-chat.mjs", "Resources/Runtime/sdk/vm-text-smoke.mjs",
        "Resources/Runtime/sdk/deepseek-text-chat.mjs", "Resources/Runtime/sdk/deepseek-text-smoke.mjs",
        "Resources/Runtime/sdk/owned-run-directory.mjs", "Resources/Runtime/sdk/package.json",
        "Resources/Runtime/translation/stdio.mjs", "Resources/Runtime/translation/client.mjs",
        "Resources/Runtime/translation/pipeline.mjs", "Resources/Runtime/translation/protected-text.mjs",
        "Resources/Runtime/translation/errors.mjs", "Resources/Runtime/network/proxy-transport.mjs",
        "Resources/Runtime/runtime/profile.mjs", "Resources/Runtime/host/text-runtime/launch.py",
        "Resources/Runtime/host/text-runtime/common.py", "Resources/Runtime/host/text-runtime/runtime-config.json",
        "Resources/Runtime/host/text-runtime/images/base.json",
        "Resources/Runtime/host/text-runtime/images/kernel", "Resources/Runtime/host/text-runtime/images/initrd",
        diskPath, "Resources/Runtime/guest/text-runtime/runtime.mjs",
        "Resources/Runtime/guest/text-runtime/bootstrap.sh", "Resources/Runtime/guest/text-runtime/supervisor.py"
    ])

    func info(id: String) -> RuntimePackageInfo {
        .init(id: id, version: version, cliVersion: cliVersion, sdkVersion: sdkVersion, nodeVersion: nodeVersion)
    }

    func validate() throws {
        guard schema == Self.schemaValue, hostProtocol == 1, platform == "macOS-arm64",
              [version, cliVersion, sdkVersion, nodeVersion, minimumOSVersion,
               minimumAppVersion, maximumAppVersionExclusive].allSatisfy(RuntimePackageIO.isVersion),
              RuntimePackageIO.compareVersion(minimumAppVersion, maximumAppVersionExclusive) < 0,
              !files.isEmpty, files.count <= 4096 else { throw RuntimePackageFailure.invalidPackage }
        var seen = Set<String>()
        var folded = Set<String>()
        var total: Int64 = 0
        for file in files {
            guard RuntimePackageIO.isPayloadPath(file.path), seen.insert(file.path).inserted,
                  folded.insert(file.path.lowercased()).inserted, file.size >= 0,
                  file.size <= 10 * 1024 * 1024 * 1024,
                  (file.path == Self.diskPath || file.size <= 128 * 1024 * 1024),
                  RuntimePackageIO.isDigest(file.sha256) else { throw RuntimePackageFailure.invalidPackage }
            total += file.size
            guard total <= 12 * 1024 * 1024 * 1024 else { throw RuntimePackageFailure.invalidPackage }
        }
        guard Self.requiredPaths.isSubset(of: seen),
              files.first(where: { $0.path == "Helpers/vm-text-runtime" })?.executable == true,
              files.first(where: { $0.path == Self.diskPath })?.executable == false else {
            throw RuntimePackageFailure.invalidPackage
        }
        // A file cannot also be a parent directory of another listed file.
        for path in seen {
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                guard !seen.contains(parent), !folded.contains(parent.lowercased()) else {
                    throw RuntimePackageFailure.invalidPackage
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
    }

    func validateCompatibility(appVersion: String) throws {
        #if arch(arm64)
        let architectureSupported = true
        #else
        let architectureSupported = false
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        guard architectureSupported, RuntimePackageIO.isVersion(appVersion),
              RuntimePackageIO.compareVersion(appVersion, minimumAppVersion) >= 0,
              RuntimePackageIO.compareVersion(appVersion, maximumAppVersionExclusive) < 0,
              RuntimePackageIO.compareVersion(osVersion, minimumOSVersion) >= 0 else {
            throw RuntimePackageFailure.incompatible
        }
    }
}

struct RuntimePackageTrust: Codable, Sendable {
    let schema: String
    let publicKeys: [String: String]
    static let schemaValue = "claude-runtime-trust/v1"
}

struct RuntimePackageSignature: Codable, Sendable {
    let schema: String
    let keyID: String
    let signature: String
    static let schemaValue = "claude-runtime-signature/v1"
}

struct RuntimePackageVerified: Sendable {
    let manifest: RuntimePackageManifest
    let bytes: Data
    let signatureBytes: Data?
    let id: String
    var info: RuntimePackageInfo { manifest.info(id: id) }
}

enum RuntimePackageIO {
    static let maximumManifestBytes = 2 * 1024 * 1024
    static let fileManager = FileManager.default

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func isVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 64 && parts.count == 3 && parts.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 9 && $0.utf8.allSatisfy { (48...57).contains($0) }
        }
    }

    static func compareVersion(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0)! }
        let right = rhs.split(separator: ".").map { Int($0)! }
        for index in 0..<3 {
            if left[index] != right[index] { return left[index] < right[index] ? -1 : 1 }
        }
        return 0
    }

    static func isPayloadPath(_ value: String) -> Bool {
        guard value.utf8.count <= 512, !value.isEmpty,
              value.utf8.allSatisfy({ (33...126).contains($0) }),
              !value.contains("\\"), !value.contains(":"), !value.contains("%") else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 128 }) else { return false }
        return value.hasPrefix("Resources/Runtime/") || value.hasPrefix("Helpers/")
    }

    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    static func statFile(_ url: URL, directory: Bool = false) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              (value.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG),
              directory || value.st_nlink == 1 else { throw RuntimePackageFailure.invalidPackage }
        return value
    }

    /// Check every ancestor so a no-follow final file open cannot traverse a linked directory.
    static func validateAncestors(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw RuntimePackageFailure.invalidPackage
        }
        // Foundation standardization rewrites physical /private/var paths to the /var symlink.
        // Keep absolute lexical components so every actual traversed ancestor is checked.
        var current = url.path
        while current != "/" {
            _ = try statFile(URL(fileURLWithPath: current), directory: true)
            current = (current as NSString).deletingLastPathComponent
        }
    }

    static func readSmall(_ url: URL, limit: Int) throws -> Data {
        let metadata = try statFile(url)
        guard metadata.st_size >= 0, metadata.st_size <= limit else { throw RuntimePackageFailure.invalidPackage }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RuntimePackageFailure.invalidPackage }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, sameIdentity(metadata, opened) else { throw RuntimePackageFailure.invalidPackage }
        var bytes = Data(count: Int(metadata.st_size))
        let count = bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let result = read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if result < 0 && errno == EINTR { continue }
                if result <= 0 { return -1 }
                offset += result
            }
            return offset
        }
        var after = stat()
        guard count == bytes.count, fstat(fd, &after) == 0, sameIdentity(opened, after) else {
            throw RuntimePackageFailure.integrityFailed
        }
        return bytes
    }

    static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size &&
        lhs.st_nlink == rhs.st_nlink && lhs.st_mode == rhs.st_mode &&
        lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
        lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    static func streamDigest(_ url: URL, shouldCancel: @Sendable () -> Bool = { false },
                             onBytes: (Int64) -> Void = { _ in }) throws -> String {
        let metadata = try statFile(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RuntimePackageFailure.integrityFailed }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, sameIdentity(metadata, opened) else { throw RuntimePackageFailure.integrityFailed }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var total: Int64 = 0
        while true {
            if shouldCancel() { throw RuntimePackageFailure.cancelled }
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw RuntimePackageFailure.integrityFailed }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
            total += Int64(count)
            onBytes(Int64(count))
        }
        var after = stat()
        guard total == metadata.st_size, fstat(fd, &after) == 0, sameIdentity(opened, after) else {
            throw RuntimePackageFailure.integrityFailed
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func decodeManifest(_ data: Data) throws -> RuntimePackageManifest {
        do {
            let manifest = try JSONDecoder().decode(RuntimePackageManifest.self, from: data)
            try manifest.validate()
            return manifest
        } catch let failure as RuntimePackageFailure { throw failure }
        catch { throw RuntimePackageFailure.invalidPackage }
    }

    static func loadTrust(_ url: URL) throws -> RuntimePackageTrust {
        do {
            let trust = try JSONDecoder().decode(RuntimePackageTrust.self, from: readSmall(url, limit: 64 * 1024))
            guard trust.schema == RuntimePackageTrust.schemaValue, !trust.publicKeys.isEmpty,
                  trust.publicKeys.count <= 32 else { throw RuntimePackageFailure.untrustedSigner }
            for (id, encoded) in trust.publicKeys {
                guard let raw = Data(base64Encoded: encoded), raw.count == 32, digest(raw) == id else {
                    throw RuntimePackageFailure.untrustedSigner
                }
                _ = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
            }
            return trust
        } catch { throw RuntimePackageFailure.untrustedSigner }
    }

    static func signedManifest(at package: URL, trust: RuntimePackageTrust) throws -> RuntimePackageVerified {
        try validateAncestors(package)
        let bytes = try readSmall(package.appendingPathComponent("manifest.json"), limit: maximumManifestBytes)
        let signatureBytes = try readSmall(package.appendingPathComponent("signature.json"), limit: 4096)
        let signature: RuntimePackageSignature
        do { signature = try JSONDecoder().decode(RuntimePackageSignature.self, from: signatureBytes) }
        catch { throw RuntimePackageFailure.invalidPackage }
        guard signature.schema == RuntimePackageSignature.schemaValue,
              let encodedKey = trust.publicKeys[signature.keyID], let rawKey = Data(base64Encoded: encodedKey),
              let rawSignature = Data(base64Encoded: signature.signature), rawSignature.count == 64 else {
            throw RuntimePackageFailure.untrustedSigner
        }
        let key: Curve25519.Signing.PublicKey
        do { key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey) }
        catch { throw RuntimePackageFailure.untrustedSigner }
        guard key.isValidSignature(rawSignature, for: bytes) else { throw RuntimePackageFailure.integrityFailed }
        let manifest = try decodeManifest(bytes)
        return .init(manifest: manifest, bytes: bytes, signatureBytes: signatureBytes, id: "runtime-" + digest(bytes))
    }

    static func expectedDirectories(_ manifest: RuntimePackageManifest) -> Set<String> {
        var directories = Set(["Resources", "Resources/Runtime", "Helpers"])
        for file in manifest.files {
            var path = (file.path as NSString).deletingLastPathComponent
            while !path.isEmpty {
                directories.insert(path)
                path = (path as NSString).deletingLastPathComponent
            }
        }
        return directories
    }

    static func inventory(_ contents: URL, manifest: RuntimePackageManifest, packageRoot: URL? = nil) throws {
        try validateAncestors(contents)
        if let root = packageRoot {
            let names: [String]
            do { names = try fileManager.contentsOfDirectory(atPath: root.path) }
            catch { throw RuntimePackageFailure.invalidPackage }
            guard Set(names) == Set(["manifest.json", "signature.json", "Contents"]) else {
                throw RuntimePackageFailure.invalidPackage
            }
        }
        let expectedFiles = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        let expectedDirs = expectedDirectories(manifest)
        var actualFiles = Set<String>()
        var actualDirs = Set<String>()
        func visit(_ directory: URL, relative: String) throws {
            let names: [String]
            do { names = try fileManager.contentsOfDirectory(atPath: directory.path) }
            catch { throw RuntimePackageFailure.invalidPackage }
            for name in names {
                let path = relative.isEmpty ? name : relative + "/" + name
                let child = directory.appendingPathComponent(name)
                var metadata = stat()
                guard lstat(child.path, &metadata) == 0 else { throw RuntimePackageFailure.invalidPackage }
                if (metadata.st_mode & S_IFMT) == S_IFDIR {
                    guard expectedDirs.contains(path), actualDirs.insert(path).inserted else { throw RuntimePackageFailure.invalidPackage }
                    try visit(child, relative: path)
                } else {
                    guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_nlink == 1,
                          let expected = expectedFiles[path], metadata.st_size == expected.size,
                          ((metadata.st_mode & 0o111) != 0) == expected.executable,
                          actualFiles.insert(path).inserted else { throw RuntimePackageFailure.integrityFailed }
                }
            }
        }
        // A bundled App also contains native App resources. Only its two runtime roots are in scope.
        if packageRoot == nil {
            for root in ["Resources/Runtime", "Helpers"] {
                let directory = contents.appendingPathComponent(root)
                try validateAncestors(directory)
                actualDirs.insert(root)
                if root == "Resources/Runtime" { actualDirs.insert("Resources") }
                try visit(directory, relative: root)
            }
        } else { try visit(contents, relative: "") }
        guard actualFiles == Set(expectedFiles.keys), actualDirs == expectedDirs else { throw RuntimePackageFailure.integrityFailed }
    }

    static func verifyPayload(_ contents: URL, manifest: RuntimePackageManifest, full: Bool,
                              packageRoot: URL? = nil, shouldCancel: @Sendable () -> Bool = { false },
                              progress: @Sendable (Double) -> Void = { _ in }) throws {
        try inventory(contents, manifest: manifest, packageRoot: packageRoot)
        let checked = manifest.files.filter { full || $0.path != RuntimePackageManifest.diskPath }
        let total = max(Int64(1), checked.reduce(Int64(0)) { $0 + $1.size })
        var completed: Int64 = 0
        for file in checked {
            guard try streamDigest(contents.appendingPathComponent(file.path), shouldCancel: shouldCancel, onBytes: { count in
                completed += count
                progress(min(1, Double(completed) / Double(total)))
            }) == file.sha256 else { throw RuntimePackageFailure.integrityFailed }
        }
        try validateBase(contents, manifest: manifest)
        progress(1)
    }

    static func validateBase(_ contents: URL, manifest: RuntimePackageManifest) throws {
        let runtime = contents.appendingPathComponent("Resources/Runtime/host/text-runtime")
        let baseData = try readSmall(runtime.appendingPathComponent("images/base.json"), limit: 64 * 1024)
        let configData = try readSmall(runtime.appendingPathComponent("runtime-config.json"), limit: 16 * 1024)
        guard let base = try? JSONSerialization.jsonObject(with: baseData) as? [String: Any],
              base["schema"] as? String == "claude-text-vm-base/v1", base["prepared"] as? Bool == true,
              base["no_user_data"] as? Bool == true, (base["network_devices"] as? NSNumber)?.intValue == 0,
              (base["directory_shares"] as? NSNumber)?.intValue == 0,
              base["node_version"] as? String == manifest.nodeVersion,
              base["sdk_version"] as? String == manifest.sdkVersion,
              base["cli_version"] as? String == manifest.cliVersion,
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              config["schema"] as? String == "claude-vm-runtime/v1", config["image_dir"] as? String == "images",
              config["runner"] as? String == "../../../../Helpers/vm-text-runtime",
              config["guest_runtime_dir"] as? String == "../../guest/text-runtime",
              config["python"] as? String == "/usr/bin/python3" else { throw RuntimePackageFailure.invalidPackage }
        for (name, key) in [("guest.raw", "disk_sha256"), ("kernel", "kernel_sha256"), ("initrd", "initrd_sha256")] {
            guard let entry = manifest.files.first(where: { $0.path == "Resources/Runtime/host/text-runtime/images/" + name }),
                  base[key] as? String == entry.sha256,
                  name != "guest.raw" || (base["disk_bytes"] as? NSNumber)?.int64Value == entry.size else {
                throw RuntimePackageFailure.integrityFailed
            }
        }
        let sdkData = try readSmall(contents.appendingPathComponent("Resources/Runtime/sdk/package.json"), limit: 64 * 1024)
        guard let sdk = try? JSONSerialization.jsonObject(with: sdkData) as? [String: Any],
              let dependencies = sdk["dependencies"] as? [String: String],
              dependencies["@anthropic-ai/claude-agent-sdk"] == manifest.sdkVersion else {
            throw RuntimePackageFailure.invalidPackage
        }
    }

    static func createPrivateDirectory(_ url: URL) throws {
        do {
            if fileManager.fileExists(atPath: url.path) {
                let metadata = try statFile(url, directory: true)
                guard metadata.st_uid == getuid() else { throw RuntimePackageFailure.persistenceFailed }
                guard chmod(url.path, 0o700) == 0 else { throw RuntimePackageFailure.persistenceFailed }
            } else { try fileManager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            try validateAncestors(url)
        } catch { throw RuntimePackageFailure.persistenceFailed }
    }

    static func atomicWrite(_ bytes: Data, to url: URL, mode: mode_t = 0o600) throws {
        let parent = url.deletingLastPathComponent()
        try validateAncestors(parent)
        let temporary = parent.appendingPathComponent(".runtime-write-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw RuntimePackageFailure.persistenceFailed }
        var didClose = false
        defer {
            if !didClose { close(fd) }
            unlink(temporary.path)
        }
        let success = bytes.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let result = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if result < 0 && errno == EINTR { continue }
                if result <= 0 { return false }
                offset += result
            }
            return true
        }
        guard success, fchmod(fd, mode) == 0, fsync(fd) == 0 else { throw RuntimePackageFailure.persistenceFailed }
        guard close(fd) == 0 else { didClose = true; throw RuntimePackageFailure.persistenceFailed }
        didClose = true
        guard rename(temporary.path, url.path) == 0 else { throw RuntimePackageFailure.persistenceFailed }
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw RuntimePackageFailure.persistenceFailed }
        defer { close(parentFD) }
        guard fsync(parentFD) == 0 else { throw RuntimePackageFailure.persistenceFailed }
    }

    static func copyPayload(from source: URL, to destination: URL, manifest: RuntimePackageManifest,
                            shouldCancel: @Sendable () -> Bool, progress: @Sendable (Double) -> Void) throws {
        do { try fileManager.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw RuntimePackageFailure.persistenceFailed }
        let dirs = expectedDirectories(manifest).sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
        for path in dirs {
            do { try fileManager.createDirectory(at: destination.appendingPathComponent(path), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            catch { throw RuntimePackageFailure.persistenceFailed }
        }
        for (index, file) in manifest.files.enumerated() {
            if shouldCancel() { throw RuntimePackageFailure.cancelled }
            let origin = source.appendingPathComponent(file.path)
            try validateAncestors(origin.deletingLastPathComponent())
            let sourceFD = open(origin.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard sourceFD >= 0 else { throw RuntimePackageFailure.integrityFailed }
            defer { close(sourceFD) }
            var opened = stat()
            guard fstat(sourceFD, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG,
                  opened.st_nlink == 1, opened.st_size == file.size else { throw RuntimePackageFailure.integrityFailed }
            let target = destination.appendingPathComponent(file.path)
            let targetDirectoryFD = open(target.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard targetDirectoryFD >= 0 else { throw RuntimePackageFailure.persistenceFailed }
            defer { close(targetDirectoryFD) }
            // clone flags on fcopyfile do not clone. fclonefileat uses the already no-follow-opened
            // source descriptor, and creates an independent COW file in our private target directory.
            let cloned = fclonefileat(sourceFD, targetDirectoryFD, target.lastPathComponent, UInt32(CLONE_NOOWNERCOPY)) == 0
            let cloneError = errno
            guard cloned || cloneError == ENOTSUP || cloneError == EXDEV else { throw RuntimePackageFailure.persistenceFailed }
            let targetFD: Int32
            if cloned {
                // The clone may inherit a read-only source mode. fchmod/fsync permit a read descriptor.
                targetFD = openat(targetDirectoryFD, target.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            } else {
                targetFD = openat(targetDirectoryFD, target.lastPathComponent,
                                  O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            }
            guard targetFD >= 0 else { throw RuntimePackageFailure.persistenceFailed }
            defer { close(targetFD) }
            if !cloned {
                guard fcopyfile(sourceFD, targetFD, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_DATA_SPARSE)) == 0 else {
                    throw RuntimePackageFailure.persistenceFailed
                }
            }
            guard fchmod(targetFD, file.executable ? 0o500 : 0o400) == 0,
                  fsync(targetFD) == 0 else { throw RuntimePackageFailure.persistenceFailed }
            var after = stat()
            guard fstat(sourceFD, &after) == 0, sameIdentity(opened, after) else { throw RuntimePackageFailure.integrityFailed }
            progress(Double(index + 1) / Double(manifest.files.count))
        }
    }

    static func sealDirectories(_ package: URL, manifest: RuntimePackageManifest, sealRoot: Bool = true) throws {
        let contents = package.appendingPathComponent("Contents")
        for path in expectedDirectories(manifest) {
            let directory = contents.appendingPathComponent(path)
            guard chmod(directory.path, 0o500) == 0 else { throw RuntimePackageFailure.persistenceFailed }
            try syncDirectory(directory)
        }
        guard chmod(contents.path, 0o500) == 0,
              chmod(package.path, sealRoot ? 0o500 : 0o700) == 0 else { throw RuntimePackageFailure.persistenceFailed }
        try syncDirectory(contents)
        try syncDirectory(package)
    }

    static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw RuntimePackageFailure.persistenceFailed }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw RuntimePackageFailure.persistenceFailed }
    }

    static func removeOwnedStaging(_ directory: URL) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        // Staging may already have been sealed before an interrupted commit.
        func makeWritable(_ current: URL) throws {
            let metadata = try statFile(current, directory: true)
            guard metadata.st_uid == getuid(), chmod(current.path, 0o700) == 0 else { throw RuntimePackageFailure.persistenceFailed }
            for name in try fileManager.contentsOfDirectory(atPath: current.path) {
                let child = current.appendingPathComponent(name)
                var entry = stat()
                guard lstat(child.path, &entry) == 0 else { throw RuntimePackageFailure.persistenceFailed }
                if (entry.st_mode & S_IFMT) == S_IFDIR { try makeWritable(child) }
            }
        }
        do { try makeWritable(directory); try fileManager.removeItem(at: directory) }
        catch { throw RuntimePackageFailure.persistenceFailed }
    }
}
