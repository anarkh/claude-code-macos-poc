import CryptoKit
import Darwin
import Foundation

enum BrowserRuntimeStorageFailure: Error, Equatable, LocalizedError, Sendable {
    case baselineMissing, invalidManifest, unsafeBaseline, integrityMismatch(String)
    case unsafeProfile, incompatibleProfile, profileBusy, apfsCloneRequired
    case storageIO(String), cleanupFailed

    var errorDescription: String? { message }
    var message: String {
        switch self {
        case .baselineMissing: "缺少独立浏览器运行环境，请重新安装包含浏览器镜像的 App。"
        case .invalidManifest: "浏览器镜像清单无效，请重新安装浏览器运行环境。"
        case .unsafeBaseline: "浏览器基线必须为只读普通文件，且路径不能包含符号链接。"
        case .integrityMismatch(let file): "浏览器镜像校验失败（\(file)），请重新安装浏览器运行环境。"
        case .unsafeProfile: "浏览器资料目录权限不安全或包含链接。请检查本 App 的 Browser 数据目录。"
        case .incompatibleProfile: "浏览器资料磁盘或清单不兼容，原资料已保留。请先关闭浏览器，再清除浏览器资料后重试。"
        case .profileBusy: "浏览器资料正在被另一个窗口或 App 实例使用。请关闭该浏览器后重试。"
        case .apfsCloneRequired: "浏览器根盘需要 APFS 克隆。请检查镜像与 App 数据目录是否在同一 APFS 卷，以及可用空间和权限。"
        case .storageIO(let operation): "浏览器本机存储操作失败（\(operation)）。请检查数据目录权限和可用空间后重试。"
        case .cleanupFailed: "浏览器临时磁盘未能清理。请关闭浏览器并检查本 App 的 Browser 数据目录后重试。"
        }
    }
}

struct BrowserRuntimeManifest: Codable, Equatable, Sendable {
    let schema: String
    let firefoxVersion: String
    let sha256: [String: String]
    let diskBytes: Int64

    enum CodingKeys: String, CodingKey {
        case schema, sha256
        case firefoxVersion = "firefox_version"
        case diskBytes = "disk_bytes"
    }

    init(schema: String = "browser-vm-base/v1", firefoxVersion: String,
         sha256: [String: String], diskBytes: Int64) {
        self.schema = schema; self.firefoxVersion = firefoxVersion
        self.sha256 = sha256; self.diskBytes = diskBytes
    }

    init(from decoder: any Decoder) throws {
        do {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            schema = try fields.decode(String.self, forKey: .schema)
            firefoxVersion = try fields.decode(String.self, forKey: .firefoxVersion)
            sha256 = try fields.decode([String: String].self, forKey: .sha256)
            diskBytes = try fields.decode(Int64.self, forKey: .diskBytes)
            try validate()
        } catch { throw BrowserRuntimeStorageFailure.invalidManifest }
    }

    func validate() throws {
        guard schema == "browser-vm-base/v1", diskBytes > 0,
              (1...64).contains(firefoxVersion.utf8.count),
              firefoxVersion.utf8.first.map({ (48...57).contains($0) }) == true,
              firefoxVersion.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              Set(sha256.keys) == ["kernel", "initrd", "guest.raw"],
              sha256.values.allSatisfy({ digest in
                  digest.utf8.count == 64 && digest.utf8.allSatisfy({
                      (48...57).contains($0) || (97...102).contains($0)
                  })
              }) else { throw BrowserRuntimeStorageFailure.invalidManifest }
    }
}

private struct BrowserProfileManifest: Codable, Equatable {
    let schema: String
    let disk_bytes: Int64

    static let current = BrowserProfileManifest(schema: "browser-profile/v1", disk_bytes: 2 * 1_024 * 1_024 * 1_024)

    static func decode(_ data: Data) throws -> Self {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["schema", "disk_bytes"] else { throw BrowserRuntimeStorageFailure.incompatibleProfile }
            let manifest = try JSONDecoder().decode(Self.self, from: data)
            guard manifest == .current else { throw BrowserRuntimeStorageFailure.incompatibleProfile }
            return manifest
        } catch { throw BrowserRuntimeStorageFailure.incompatibleProfile }
    }
}

struct BrowserPreparedRuntime: Sendable {
    let kernelURL: URL
    let initrdURL: URL
    /// Disposable APFS clone of the verified browser root, attached as /dev/vda.
    let diskURL: URL
    /// Persistent browser home volume, attached as /dev/vdb.
    let profileDiskURL: URL
    let configDiskURL: URL
    let manifest: BrowserRuntimeManifest
    let lease: BrowserProfileLease
}

/// The controller must retain this lease during preparation, startup, running and stopping,
/// and call release only after Virtualization reports the VM completely stopped.
final class BrowserProfileLease: @unchecked Sendable {
    private let mutex = NSLock()
    private var directoryDescriptor: Int32?
    private var lockDescriptor: Int32?
    private var sessionDirectory: (name: String, metadata: stat)?

    fileprivate init(directoryDescriptor: Int32, lockDescriptor: Int32) {
        self.directoryDescriptor = directoryDescriptor; self.lockDescriptor = lockDescriptor
    }

    fileprivate func registerSessionDirectory(name: String, metadata: stat) {
        mutex.lock(); defer { mutex.unlock() }
        precondition(directoryDescriptor != nil && sessionDirectory == nil)
        sessionDirectory = (name, metadata)
    }

    /// Removes only this lease's disposable root. Closing the lock descriptor releases flock.
    /// Cleanup failure is reported, while the lock is always released; a subsequent prepare
    /// can recover an orphan root after proving that no VM holds the lock.
    func release() throws {
        mutex.lock(); defer { mutex.unlock() }
        guard let directoryDescriptor else { return }
        var cleanupFailed = false
        if let sessionDirectory {
            do { try BrowserRuntimeIO.removeSessionDirectory(sessionDirectory.name, at: directoryDescriptor, expected: sessionDirectory.metadata) }
            catch { cleanupFailed = true }
        }
        self.sessionDirectory = nil
        self.directoryDescriptor = nil
        if let lockDescriptor {
            self.lockDescriptor = nil
            if Darwin.close(lockDescriptor) != 0 { cleanupFailed = true }
        }
        if Darwin.close(directoryDescriptor) != 0 { cleanupFailed = true }
        if cleanupFailed { throw BrowserRuntimeStorageFailure.cleanupFailed }
    }

    deinit {
        do { try release() }
        catch { fputs("BROWSER_PROFILE_LEASE_CLEANUP_FAILED\n", stderr) }
    }
}

struct BrowserRuntimeStorage: Sendable {
    typealias CloneOperation = @Sendable (Int32, Int32, String) throws -> Void
    static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeIsolationPoC/Browser", isDirectory: true)
    }

    let profileDirectoryURL: URL
    private let bundleResourcesURL: URL?
    private let developmentProjectRoot: String?
    private let cloneOperation: CloneOperation

    init(bundleResourcesURL: URL? = Bundle.main.resourceURL,
         developmentProjectRoot: String? = nil,
         profileDirectoryURL: URL = BrowserRuntimeStorage.defaultDirectoryURL,
         cloneOperation: CloneOperation? = nil) {
        self.bundleResourcesURL = bundleResourcesURL
        self.developmentProjectRoot = developmentProjectRoot
        self.profileDirectoryURL = profileDirectoryURL
        self.cloneOperation = cloneOperation ?? { source, directory, name in
            try Self.cloneRoot(source: source, destinationDirectory: directory, name: name)
        }
    }

    /// Hashing is intentionally synchronous and cancellable so callers can run it in Task.detached.
    /// No CLI VM, host browser profile, keychain or web content is read by this storage layer.
    func prepare(resistFingerprinting: Bool = false) throws -> BrowserPreparedRuntime {
        try Task.checkCancellation()
        let (directoryDescriptor, lease) = try acquireLease()
        do {
            let images = try baselineDirectory()
            let manifestFile = try BrowserBaselineFile(images.appendingPathComponent("browser.json"))
            let manifest: BrowserRuntimeManifest
            do { manifest = try JSONDecoder().decode(BrowserRuntimeManifest.self, from: manifestFile.readSmall(limit: 32 * 1_024)) }
            catch let failure as BrowserRuntimeStorageFailure { throw failure }
            catch { throw BrowserRuntimeStorageFailure.invalidManifest }

            let kernel = try BrowserBaselineFile(images.appendingPathComponent("kernel"))
            let initrd = try BrowserBaselineFile(images.appendingPathComponent("initrd"))
            let root = try BrowserBaselineFile(images.appendingPathComponent("guest.raw"))
            guard root.metadata.st_size == manifest.diskBytes else { throw BrowserRuntimeStorageFailure.integrityMismatch("guest.raw") }
            for file in [kernel, initrd, root] {
                guard try file.digest() == manifest.sha256[file.url.lastPathComponent] else {
                    throw BrowserRuntimeStorageFailure.integrityMismatch(file.url.lastPathComponent)
                }
            }
            try Task.checkCancellation()
            try BrowserRuntimeIO.requireAPFS(root.descriptor)
            try BrowserRuntimeIO.requireAPFS(directoryDescriptor)
            try removeOrphanSessions(at: directoryDescriptor)
            try prepareProfile(at: directoryDescriptor)
            try Task.checkCancellation()
            let sessionName = ".browser-session-\(UUID().uuidString.lowercased())"
            guard Darwin.mkdirat(directoryDescriptor, sessionName, 0o700) == 0 else {
                throw BrowserRuntimeStorageFailure.storageIO("创建浏览器临时目录")
            }
            let sessionMetadata = try BrowserRuntimeIO.metadata(sessionName, at: directoryDescriptor)
            lease.registerSessionDirectory(name: sessionName, metadata: sessionMetadata)
            let sessionDescriptor = Darwin.openat(directoryDescriptor, sessionName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard sessionDescriptor >= 0 else { throw BrowserRuntimeStorageFailure.unsafeProfile }
            defer { Darwin.close(sessionDescriptor) }
            let sessionURL = profileDirectoryURL.appendingPathComponent(sessionName, isDirectory: true)
            try cloneOperation(root.descriptor, sessionDescriptor, "root.raw")
            // clonefile preserves the baseline's 0400 mode; open read-only before fchmod.
            let cloneDescriptor = Darwin.openat(sessionDescriptor, "root.raw", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard cloneDescriptor >= 0 else { throw BrowserRuntimeStorageFailure.storageIO("打开临时根盘") }
            defer { Darwin.close(cloneDescriptor) }
            guard Darwin.fchmod(cloneDescriptor, 0o600) == 0 else { throw BrowserRuntimeStorageFailure.storageIO("设置临时根盘权限") }
            try BrowserRuntimeIO.validatePrivateFile(cloneDescriptor, expectedSize: manifest.diskBytes)
            try root.assertUnchanged()
            try kernel.assertUnchanged(); try initrd.assertUnchanged(); try manifestFile.assertUnchanged()
            try Task.checkCancellation()
            try prepareConfig(resistFingerprinting: resistFingerprinting, sessionURL: sessionURL, descriptor: sessionDescriptor)
            try Task.checkCancellation()
            try BrowserRuntimeIO.assertDirectory(profileDirectoryURL, descriptor: directoryDescriptor)
            return BrowserPreparedRuntime(kernelURL: kernel.url, initrdURL: initrd.url,
                                          diskURL: sessionURL.appendingPathComponent("root.raw"),
                                          profileDiskURL: profileDirectoryURL.appendingPathComponent("profile.raw"),
                                          configDiskURL: sessionURL.appendingPathComponent("config.iso"),
                                          manifest: manifest, lease: lease)
        } catch {
            do { try lease.release() }
            catch { throw BrowserRuntimeStorageFailure.cleanupFailed }
            throw error
        }
    }

    /// Acquiring the VM's same exclusive lock proves that no cooperating VM is starting or active.
    /// Only the two persistent browser profile files are removed; unrelated files and root clones remain.
    func clearProfile() throws {
        let (directoryDescriptor, lease) = try acquireLease()
        do {
            var files: [(String, stat)] = []
            for name in ["profile.raw", "profile.json"] {
                if let metadata = try BrowserRuntimeIO.optionalMetadata(name, at: directoryDescriptor) {
                    try BrowserRuntimeIO.validateOwnedMetadata(metadata)
                    files.append((name, metadata))
                }
            }
            try BrowserRuntimeIO.assertDirectory(profileDirectoryURL, descriptor: directoryDescriptor)
            for (name, metadata) in files { try BrowserRuntimeIO.unlinkOwned(name, at: directoryDescriptor, expected: metadata) }
            guard Darwin.fsync(directoryDescriptor) == 0 else { throw BrowserRuntimeStorageFailure.storageIO("确认资料清除") }
            try lease.release()
        } catch {
            do { try lease.release() }
            catch { throw BrowserRuntimeStorageFailure.cleanupFailed }
            throw error
        }
    }

    private func baselineDirectory() throws -> URL {
        if let bundleResourcesURL {
            let images = bundleResourcesURL.appendingPathComponent("BrowserRuntime/images", isDirectory: true)
            var metadata = stat()
            if Darwin.lstat(images.path, &metadata) == 0 { return images }
            guard errno == ENOENT else { throw BrowserRuntimeStorageFailure.unsafeBaseline }
        }
        guard Bundle.main.bundleURL.pathExtension != "app",
              let developmentProjectRoot, developmentProjectRoot.hasPrefix("/") else {
            throw BrowserRuntimeStorageFailure.baselineMissing
        }
        let images = URL(fileURLWithPath: developmentProjectRoot, isDirectory: true)
            .appendingPathComponent("host/browser-runtime/images", isDirectory: true)
        var metadata = stat()
        guard Darwin.lstat(images.path, &metadata) == 0 else { throw BrowserRuntimeStorageFailure.baselineMissing }
        return images
    }

    private func acquireLease() throws -> (Int32, BrowserProfileLease) {
        try BrowserRuntimeIO.ensurePrivateDirectory(profileDirectoryURL)
        let directoryDescriptor = Darwin.open(profileDirectoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw BrowserRuntimeStorageFailure.unsafeProfile }
        var lockDescriptor: Int32 = -1
        do {
            try BrowserRuntimeIO.assertDirectory(profileDirectoryURL, descriptor: directoryDescriptor)
            lockDescriptor = Darwin.openat(directoryDescriptor, "profile.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard lockDescriptor >= 0 else { throw BrowserRuntimeStorageFailure.unsafeProfile }
            try BrowserRuntimeIO.validatePrivateFile(lockDescriptor)
            var metadata = stat()
            guard Darwin.fstat(lockDescriptor, &metadata) == 0,
                  BrowserRuntimeIO.sameIdentity(metadata, try BrowserRuntimeIO.metadata("profile.lock", at: directoryDescriptor)) else {
                throw BrowserRuntimeStorageFailure.unsafeProfile
            }
            while flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
                if errno == EINTR { try Task.checkCancellation(); continue }
                if errno == EWOULDBLOCK || errno == EAGAIN { throw BrowserRuntimeStorageFailure.profileBusy }
                throw BrowserRuntimeStorageFailure.storageIO("取得资料锁")
            }
            return (directoryDescriptor, BrowserProfileLease(directoryDescriptor: directoryDescriptor, lockDescriptor: lockDescriptor))
        } catch {
            if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }
            Darwin.close(directoryDescriptor)
            throw error
        }
    }

    private func prepareProfile(at directoryDescriptor: Int32) throws {
        let raw = try BrowserRuntimeIO.optionalMetadata("profile.raw", at: directoryDescriptor)
        let json = try BrowserRuntimeIO.optionalMetadata("profile.json", at: directoryDescriptor)
        if raw != nil || json != nil {
            guard let raw, json != nil else { throw BrowserRuntimeStorageFailure.incompatibleProfile }
            let profileDescriptor = Darwin.openat(directoryDescriptor, "profile.raw", O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard profileDescriptor >= 0 else { throw BrowserRuntimeStorageFailure.unsafeProfile }
            defer { Darwin.close(profileDescriptor) }
            try BrowserRuntimeIO.validatePrivateFile(profileDescriptor, expectedSize: BrowserProfileManifest.current.disk_bytes)
            var opened = stat()
            guard Darwin.fstat(profileDescriptor, &opened) == 0,
                  BrowserRuntimeIO.sameIdentity(raw, opened),
                  BrowserRuntimeIO.sameIdentity(opened, try BrowserRuntimeIO.metadata("profile.raw", at: directoryDescriptor)) else {
                throw BrowserRuntimeStorageFailure.unsafeProfile
            }
            _ = try BrowserProfileManifest.decode(BrowserRuntimeIO.readPrivateSmall("profile.json", at: directoryDescriptor, limit: 1_024))
            return
        }
        // A sparse all-zero disk is formatted only by the guest, without a host filesystem mount.
        let rawName = ".profile-create-\(UUID().uuidString.lowercased()).raw"
        let jsonName = ".profile-create-\(UUID().uuidString.lowercased()).json"
        var owned: [(String, stat)] = []
        do {
            let rawDescriptor = Darwin.openat(directoryDescriptor, rawName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard rawDescriptor >= 0 else { throw BrowserRuntimeStorageFailure.storageIO("创建资料磁盘") }
            defer { Darwin.close(rawDescriptor) }
            owned.append((rawName, try BrowserRuntimeIO.metadata(rawName, at: directoryDescriptor)))
            guard Darwin.fchmod(rawDescriptor, 0o600) == 0,
                  Darwin.ftruncate(rawDescriptor, BrowserProfileManifest.current.disk_bytes) == 0,
                  Darwin.fsync(rawDescriptor) == 0 else { throw BrowserRuntimeStorageFailure.storageIO("初始化资料磁盘") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try BrowserRuntimeIO.writeExclusive(encoder.encode(BrowserProfileManifest.current), name: jsonName, at: directoryDescriptor)
            owned.append((jsonName, try BrowserRuntimeIO.metadata(jsonName, at: directoryDescriptor)))
            try Task.checkCancellation()
            guard Darwin.renameatx_np(directoryDescriptor, rawName, directoryDescriptor, "profile.raw", UInt32(RENAME_EXCL)) == 0 else {
                throw BrowserRuntimeStorageFailure.storageIO("保存资料磁盘")
            }
            owned[0].0 = "profile.raw"
            guard Darwin.renameatx_np(directoryDescriptor, jsonName, directoryDescriptor, "profile.json", UInt32(RENAME_EXCL)) == 0 else {
                throw BrowserRuntimeStorageFailure.storageIO("保存资料清单")
            }
            owned[1].0 = "profile.json"
            guard Darwin.fsync(directoryDescriptor) == 0 else { throw BrowserRuntimeStorageFailure.storageIO("确认资料保存") }
        } catch {
            for (name, metadata) in owned {
                do { try BrowserRuntimeIO.unlinkOwned(name, at: directoryDescriptor, expected: metadata) }
                catch { throw BrowserRuntimeStorageFailure.cleanupFailed }
            }
            throw error
        }
    }

    private func removeOrphanSessions(at directoryDescriptor: Int32) throws {
        // This runs only under the exclusive lock. A crashed process has no live VM lease.
        for name in try FileManager.default.contentsOfDirectory(atPath: profileDirectoryURL.path) {
            guard name.hasPrefix(".browser-session-"),
                  UUID(uuidString: String(name.dropFirst(17))) != nil else { continue }
            let metadata = try BrowserRuntimeIO.metadata(name, at: directoryDescriptor)
            try BrowserRuntimeIO.removeSessionDirectory(name, at: directoryDescriptor, expected: metadata)
        }
    }

    private func prepareConfig(resistFingerprinting: Bool, sessionURL: URL, descriptor: Int32) throws {
        guard Darwin.mkdirat(descriptor, "seed", 0o700) == 0 else { throw BrowserRuntimeStorageFailure.storageIO("创建浏览器配置目录") }
        let seedDescriptor = Darwin.openat(descriptor, "seed", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard seedDescriptor >= 0 else { throw BrowserRuntimeStorageFailure.unsafeProfile }
        defer { Darwin.close(seedDescriptor) }
        let payload: [String: Any] = ["schema": "browser-session-config/v1", "resist_fingerprinting": resistFingerprinting,
                                    "boot_epoch_seconds": Int(Date().timeIntervalSince1970)]
        try BrowserRuntimeIO.writeExclusive(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                                            name: "browser-config.json", at: seedDescriptor)
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["makehybrid", "-iso", "-joliet", "-o", sessionURL.appendingPathComponent("config.iso").path,
                             sessionURL.appendingPathComponent("seed", isDirectory: true).path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw BrowserRuntimeStorageFailure.storageIO("生成浏览器配置磁盘") }
        while process.isRunning {
            if Task.isCancelled {
                process.terminate(); process.waitUntilExit()
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BrowserRuntimeStorageFailure.storageIO("生成浏览器配置磁盘") }
        let configDescriptor = Darwin.openat(descriptor, "config.iso", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard configDescriptor >= 0 else { throw BrowserRuntimeStorageFailure.unsafeProfile }
        defer { Darwin.close(configDescriptor) }
        guard Darwin.fchmod(configDescriptor, 0o600) == 0 else { throw BrowserRuntimeStorageFailure.storageIO("设置配置磁盘权限") }
        try BrowserRuntimeIO.validatePrivateFile(configDescriptor)
        try BrowserRuntimeIO.assertDirectory(sessionURL, descriptor: descriptor)
        try Task.checkCancellation()
    }

    private static func cloneRoot(source: Int32, destinationDirectory: Int32, name: String) throws {
        let flags = UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY | CLONE_NOFOLLOW_ANY)
        guard Darwin.fclonefileat(source, destinationDirectory, name, flags) == 0 else {
            throw BrowserRuntimeStorageFailure.apfsCloneRequired
        }
    }
}

/// The hash and clone source are the same O_NOFOLLOW descriptor. Metadata and path identity
/// are checked before and after reading, including timestamps, to detect replacement or writes.
final class BrowserBaselineFile {
    let url: URL
    let descriptor: Int32
    let metadata: stat

    init(_ url: URL) throws {
        self.url = url
        do { try BrowserRuntimeIO.validateAncestors(url.deletingLastPathComponent()) }
        catch { throw BrowserRuntimeStorageFailure.unsafeBaseline }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw BrowserRuntimeStorageFailure.unsafeBaseline }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_mode & 0o222 == 0,
              metadata.st_size > 0 else {
            Darwin.close(descriptor); throw BrowserRuntimeStorageFailure.unsafeBaseline
        }
        var atPath = stat()
        guard Darwin.lstat(url.path, &atPath) == 0, BrowserRuntimeIO.sameSnapshot(metadata, atPath) else {
            Darwin.close(descriptor); throw BrowserRuntimeStorageFailure.unsafeBaseline
        }
        self.descriptor = descriptor; self.metadata = metadata
    }

    deinit { Darwin.close(descriptor) }

    func assertUnchanged() throws {
        var current = stat(); var atPath = stat()
        guard Darwin.fstat(descriptor, &current) == 0, Darwin.lstat(url.path, &atPath) == 0,
              BrowserRuntimeIO.sameSnapshot(metadata, current), BrowserRuntimeIO.sameSnapshot(current, atPath) else {
            throw BrowserRuntimeStorageFailure.unsafeBaseline
        }
    }

    func readSmall(limit: Int) throws -> Data {
        guard metadata.st_size <= limit else { throw BrowserRuntimeStorageFailure.invalidManifest }
        let data = try read { _ in }
        try assertUnchanged()
        return data
    }

    func digest(onChunk: (() throws -> Void)? = nil) throws -> String {
        var hasher = SHA256()
        _ = try read(collect: false) { chunk in hasher.update(data: chunk); try onChunk?() }
        try assertUnchanged()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func read(collect: Bool = true, consume: (Data) throws -> Void) throws -> Data {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else { throw BrowserRuntimeStorageFailure.unsafeBaseline }
        var output = Data(); var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw BrowserRuntimeStorageFailure.unsafeBaseline }
            if count == 0 { break }
            total += Int64(count)
            guard total <= metadata.st_size else { throw BrowserRuntimeStorageFailure.unsafeBaseline }
            let chunk = Data(buffer.prefix(count))
            if collect { output.append(chunk) }
            try consume(chunk)
        }
        guard total == metadata.st_size else { throw BrowserRuntimeStorageFailure.unsafeBaseline }
        return output
    }
}

enum BrowserRuntimeIO {
    static func sameIdentity(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    static func sameSnapshot(_ first: stat, _ second: stat) -> Bool {
        sameIdentity(first, second) && first.st_size == second.st_size && first.st_mode == second.st_mode &&
        first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec &&
        first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

    static func validateAncestors(_ directory: URL) throws {
        // Foundation standardization rewrites /private/var to the symlink /var on macOS.
        // Inspect the supplied filesystem path directly so no-follow validation stays literal.
        var path = directory.path
        guard path.hasPrefix("/") else { throw BrowserRuntimeStorageFailure.unsafeProfile }
        while true {
            var metadata = stat()
            guard Darwin.lstat(path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw BrowserRuntimeStorageFailure.unsafeProfile
            }
            if path == "/" { return }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    static func ensurePrivateDirectory(_ directory: URL) throws {
        var metadata = stat()
        if Darwin.lstat(directory.path, &metadata) != 0 {
            guard errno == ENOENT, directory.path != "/" else { throw BrowserRuntimeStorageFailure.unsafeProfile }
            let parent = directory.deletingLastPathComponent()
            var parentMetadata = stat()
            if Darwin.lstat(parent.path, &parentMetadata) != 0 {
                guard errno == ENOENT else { throw BrowserRuntimeStorageFailure.unsafeProfile }
                try ensurePrivateDirectory(parent)
            }
            try validateAncestors(parent)
            guard Darwin.mkdir(directory.path, 0o700) == 0 || errno == EEXIST else {
                throw BrowserRuntimeStorageFailure.storageIO("创建资料目录")
            }
        }
        try validateAncestors(directory)
        guard Darwin.lstat(directory.path, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & 0o777 == 0o700 else { throw BrowserRuntimeStorageFailure.unsafeProfile }
    }

    static func assertDirectory(_ url: URL, descriptor: Int32) throws {
        var opened = stat(); var atPath = stat()
        guard Darwin.fstat(descriptor, &opened) == 0, Darwin.lstat(url.path, &atPath) == 0,
              sameIdentity(opened, atPath), (opened.st_mode & S_IFMT) == S_IFDIR,
              opened.st_uid == getuid(), opened.st_mode & 0o777 == 0o700 else {
            throw BrowserRuntimeStorageFailure.unsafeProfile
        }
        try validateAncestors(url)
    }

    static func optionalMetadata(_ name: String, at directory: Int32) throws -> stat? {
        var metadata = stat()
        if Darwin.fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw BrowserRuntimeStorageFailure.unsafeProfile
        }
        return metadata
    }

    static func metadata(_ name: String, at directory: Int32) throws -> stat {
        guard let metadata = try optionalMetadata(name, at: directory) else { throw BrowserRuntimeStorageFailure.unsafeProfile }
        return metadata
    }

    static func validateOwnedMetadata(_ metadata: stat) throws {
        guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_uid == getuid(), metadata.st_nlink == 1,
              metadata.st_mode & 0o077 == 0 else { throw BrowserRuntimeStorageFailure.unsafeProfile }
    }

    static func validatePrivateFile(_ descriptor: Int32, expectedSize: Int64? = nil) throws {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { throw BrowserRuntimeStorageFailure.unsafeProfile }
        try validateOwnedMetadata(metadata)
        guard metadata.st_mode & 0o777 == 0o600,
              expectedSize.map({ metadata.st_size == $0 }) ?? true else { throw BrowserRuntimeStorageFailure.incompatibleProfile }
    }

    static func unlinkOwned(_ name: String, at directory: Int32, expected: stat) throws {
        guard let current = try optionalMetadata(name, at: directory) else { return }
        guard (current.st_mode & S_IFMT) == S_IFREG, current.st_uid == getuid(), current.st_nlink == 1,
              sameIdentity(current, expected), Darwin.unlinkat(directory, name, 0) == 0 else {
            throw BrowserRuntimeStorageFailure.cleanupFailed
        }
    }

    static func removeSessionDirectory(_ name: String, at parent: Int32, expected: stat) throws {
        guard let metadata = try optionalMetadata(name, at: parent) else { return }
        guard sameIdentity(metadata, expected), (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o700 else { throw BrowserRuntimeStorageFailure.cleanupFailed }
        let directory = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw BrowserRuntimeStorageFailure.cleanupFailed }
        defer { Darwin.close(directory) }
        var opened = stat()
        guard Darwin.fstat(directory, &opened) == 0, sameIdentity(opened, metadata) else { throw BrowserRuntimeStorageFailure.cleanupFailed }
        for file in ["root.raw", "config.iso"] {
            if let child = try optionalMetadata(file, at: directory) { try unlinkOwned(file, at: directory, expected: child) }
        }
        if let seed = try optionalMetadata("seed", at: directory) {
            guard (seed.st_mode & S_IFMT) == S_IFDIR, seed.st_uid == getuid(), seed.st_mode & 0o777 == 0o700 else {
                throw BrowserRuntimeStorageFailure.cleanupFailed
            }
            let seedDescriptor = Darwin.openat(directory, "seed", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard seedDescriptor >= 0 else { throw BrowserRuntimeStorageFailure.cleanupFailed }
            defer { Darwin.close(seedDescriptor) }
            var openedSeed = stat()
            guard Darwin.fstat(seedDescriptor, &openedSeed) == 0, sameIdentity(openedSeed, seed) else {
                throw BrowserRuntimeStorageFailure.cleanupFailed
            }
            if let file = try optionalMetadata("browser-config.json", at: seedDescriptor) {
                try unlinkOwned("browser-config.json", at: seedDescriptor, expected: file)
            }
            guard sameIdentity(seed, try self.metadata("seed", at: directory)), Darwin.unlinkat(directory, "seed", AT_REMOVEDIR) == 0 else {
                throw BrowserRuntimeStorageFailure.cleanupFailed
            }
        }
        guard sameIdentity(metadata, try self.metadata(name, at: parent)), Darwin.unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
            throw BrowserRuntimeStorageFailure.cleanupFailed
        }
    }

    static func requireAPFS(_ descriptor: Int32) throws {
        var volume = statfs()
        guard Darwin.fstatfs(descriptor, &volume) == 0 else { throw BrowserRuntimeStorageFailure.apfsCloneRequired }
        let name = withUnsafeBytes(of: volume.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard name == "apfs" else { throw BrowserRuntimeStorageFailure.apfsCloneRequired }
    }

    static func readPrivateSmall(_ name: String, at directory: Int32, limit: Int) throws -> Data {
        let descriptor = Darwin.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw BrowserRuntimeStorageFailure.unsafeProfile }
        defer { Darwin.close(descriptor) }
        try validatePrivateFile(descriptor)
        var before = stat(); guard Darwin.fstat(descriptor, &before) == 0, before.st_size > 0, before.st_size <= limit else {
            throw BrowserRuntimeStorageFailure.incompatibleProfile
        }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size)); var offset = 0
        try bytes.withUnsafeMutableBytes { buffer in
            while offset < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw BrowserRuntimeStorageFailure.incompatibleProfile }
                offset += count
            }
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0, sameSnapshot(before, after),
              sameSnapshot(after, try metadata(name, at: directory)) else { throw BrowserRuntimeStorageFailure.unsafeProfile }
        return Data(bytes)
    }

    static func writeExclusive(_ data: Data, name: String, at directory: Int32) throws {
        let descriptor = Darwin.openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BrowserRuntimeStorageFailure.storageIO("创建资料清单") }
        defer { Darwin.close(descriptor) }
        do {
            guard Darwin.fchmod(descriptor, 0o600) == 0 else { throw BrowserRuntimeStorageFailure.storageIO("设置资料清单权限") }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw BrowserRuntimeStorageFailure.storageIO("写入资料清单") }
                    offset += count
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw BrowserRuntimeStorageFailure.storageIO("确认资料清单") }
        } catch {
            guard Darwin.unlinkat(directory, name, 0) == 0 else { throw BrowserRuntimeStorageFailure.cleanupFailed }
            throw error
        }
    }
}
