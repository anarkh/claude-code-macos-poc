import Darwin
import Foundation

enum OwnedRuntimeCleanupStatus: String, Sendable { case eligible, active, manual, failed, deleted, changed }

struct OwnedRuntimeCleanupItem: Identifiable, Sendable {
    let id: UUID
    let status: OwnedRuntimeCleanupStatus
    let reason: String
    let blocksReset: Bool
    fileprivate let name: String
    fileprivate let identity: OwnedRuntimeIdentity?
    fileprivate let receipt: Data?
}

struct OwnedRuntimeCleanupSnapshot: Sendable {
    let items: [OwnedRuntimeCleanupItem]
    var hasActiveOwnedRuns: Bool { items.contains { $0.status == .active } }
    var hasBlockingRuns: Bool { items.contains(where: \.blocksReset) }
    var eligibleCount: Int { items.filter { $0.status == .eligible }.count }
    var manualCount: Int { items.filter { $0.status == .manual }.count }
    fileprivate let parent: OwnedRuntimeIdentity
}

struct OwnedRuntimeCleanupResult: Sendable {
    let items: [OwnedRuntimeCleanupItem]
    var deletedCount: Int { items.filter { $0.status == .deleted }.count }
    var activeCount: Int { items.filter { $0.status == .active }.count }
    var manualCount: Int { items.filter { $0.status == .manual }.count }
    var failedCount: Int { items.filter { $0.status == .failed || $0.status == .changed }.count }
    var hasBlockingRuns: Bool { items.contains(where: \.blocksReset) }
}

enum OwnedRuntimeCleanupFailure: String, Error, LocalizedError {
    case scanUnavailable, invalidDirectory, directoryChanged, invalidManifest, unsafeEntry, limitExceeded, deletionFailed
    var errorDescription: String? {
        switch self {
        case .scanUnavailable: "无法检查本 App 的临时运行目录，请检查目录权限后重试。"
        case .invalidDirectory, .directoryChanged: "临时运行目录发生变化或使用符号链接，已保留，请重新扫描。"
        case .invalidManifest: "临时目录缺少有效的 App 归属记录，已保留，需手动检查。"
        case .unsafeEntry: "临时目录包含无法安全处理的项目，已保留剩余内容。"
        case .limitExceeded: "临时目录超过安全扫描限制，已保留剩余内容，需手动检查。"
        case .deletionFailed: "部分临时运行文件未能删除，请重新扫描查看结果。"
        }
    }
}

fileprivate struct OwnedRuntimeIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let uid: UInt32
    init(_ value: stat) {
        device = UInt64(UInt32(bitPattern: value.st_dev)); inode = UInt64(value.st_ino); uid = value.st_uid
    }
}

private struct OwnedRuntimeManifest: Decodable {
    let schema: String
    let run_id: UUID
    let uid: UInt32
    let pid: Int32
    let kind: String
    let directory_dev: String
    let directory_ino: String
    let native_state: String
    let native_pid: Int32?
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(["schema", "run_id", "uid", "pid", "kind", "directory_dev", "directory_ino", "native_state", "native_pid"]) else {
            throw OwnedRuntimeCleanupFailure.invalidManifest
        }
        func key(_ name: String) -> Key { Key(stringValue: name)! }
        schema = try fields.decode(String.self, forKey: key("schema"))
        run_id = try fields.decode(UUID.self, forKey: key("run_id"))
        uid = try fields.decode(UInt32.self, forKey: key("uid"))
        pid = try fields.decode(Int32.self, forKey: key("pid"))
        kind = try fields.decode(String.self, forKey: key("kind"))
        directory_dev = try fields.decode(String.self, forKey: key("directory_dev"))
        directory_ino = try fields.decode(String.self, forKey: key("directory_ino"))
        native_state = try fields.decode(String.self, forKey: key("native_state"))
        native_pid = try fields.decodeIfPresent(Int32.self, forKey: key("native_pid"))
        guard schema == "claude-isolation-owned-run/v1", pid > 1,
              ["chat", "text-smoke"].contains(kind), ["not-started", "pending", "registered"].contains(native_state),
              directory_dev.range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil,
              directory_ino.range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil,
              UInt64(directory_dev) != nil, UInt64(directory_ino) != nil,
              native_state == "registered" ? (native_pid ?? 0) > 1 : native_pid == nil else {
            throw OwnedRuntimeCleanupFailure.invalidManifest
        }
    }
}

/// Scopes all traversal to directory descriptors opened with O_NOFOLLOW. A
/// candidate's ownership receipt, inode and process liveness are rechecked at
/// deletion time. Old unmarked directories are never adopted or removed.
final class OwnedRuntimeCleanupService {
    static let manifestName = ".claude-isolation-owner.json"
    static func defaultTemporaryRoot() throws -> URL {
        // Foundation intentionally abbreviates /private/var back to /var;
        // POSIX realpath is required before no-follow ancestor traversal.
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw OwnedRuntimeCleanupFailure.scanUnavailable
        }
        defer { free(physical) }
        return URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    }
    private let tempRoot: URL?
    private let expectedUID: UInt32
    private let processAlive: (Int32) -> Bool

    init(tempRoot: URL? = nil,
         processAlive: @escaping (Int32) -> Bool = { pid in
             if Darwin.kill(pid, 0) == 0 { return true }
             return errno != ESRCH // EPERM and other uncertainty are not proof of exit.
         }) {
        self.tempRoot = tempRoot
        expectedUID = getuid()
        self.processAlive = processAlive
    }

    func scan() throws -> OwnedRuntimeCleanupSnapshot {
        let parent = try openParent()
        defer { Darwin.close(parent) }
        let identity = try directoryIdentity(parent)
        var items: [OwnedRuntimeCleanupItem] = []
        for name in try entries(parent) where isCandidate(name) {
            items.append(inspect(parent: parent, name: name))
        }
        return .init(items: items, parent: identity)
    }

    func cleanup(_ snapshot: OwnedRuntimeCleanupSnapshot) -> OwnedRuntimeCleanupResult {
        let parent: Int32
        do {
            parent = try openParent()
            guard try directoryIdentity(parent) == snapshot.parent else {
                Darwin.close(parent); throw OwnedRuntimeCleanupFailure.directoryChanged
            }
        } catch {
            return .init(items: snapshot.items.map { replacement($0, status: .changed, reason: "parent_changed", blocks: $0.blocksReset) })
        }
        defer { Darwin.close(parent) }
        return .init(items: snapshot.items.map { original in
            guard original.status == .eligible else { return original }
            let current = inspect(parent: parent, name: original.name, id: original.id)
            guard current.status == .eligible else { return current }
            guard current.identity == original.identity, current.receipt == original.receipt else {
                return replacement(original, status: .changed, reason: "candidate_changed")
            }
            do {
                // Rename atomically to an unguessable, still discoverable name.
                // Verify the moved inode before touching any of its contents.
                let prefix = original.name.hasPrefix("claude-deepseek-chat-") ? "claude-deepseek-chat-" : "claude-deepseek-text-"
                let quarantine = prefix + "cleanup-" + UUID().uuidString.lowercased()
                guard renameatx_np(parent, original.name, parent, quarantine, UInt32(RENAME_EXCL)) == 0 else {
                    throw OwnedRuntimeCleanupFailure.deletionFailed
                }
                let moved = inspect(parent: parent, name: quarantine, id: original.id)
                guard moved.status == .eligible, moved.identity == original.identity, moved.receipt == original.receipt else {
                    return replacement(moved, status: moved.blocksReset ? moved.status : .changed, reason: "candidate_changed", blocks: moved.blocksReset)
                }
                let root = openat(parent, quarantine, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard root >= 0 else { throw OwnedRuntimeCleanupFailure.directoryChanged }
                defer { Darwin.close(root) }
                guard try directoryIdentity(root) == original.identity else { throw OwnedRuntimeCleanupFailure.directoryChanged }
                var budget = 20_000
                try removeContents(root, rootIdentity: original.identity!, depth: 0, budget: &budget)
                // Remove the receipt last so an interrupted deletion remains a
                // recognizable owned root. An empty interrupted root is manual.
                guard unlinkat(root, Self.manifestName, 0) == 0 else { throw OwnedRuntimeCleanupFailure.deletionFailed }
                guard identityAt(parent, quarantine) == original.identity,
                      unlinkat(parent, quarantine, AT_REMOVEDIR) == 0 else { throw OwnedRuntimeCleanupFailure.deletionFailed }
                return replacement(original, status: .deleted, reason: "removed")
            } catch let failure as OwnedRuntimeCleanupFailure {
                return replacement(original, status: .failed, reason: failure.rawValue)
            } catch { return replacement(original, status: .failed, reason: "deletion_failed") }
        })
    }

    private func inspect(parent: Int32, name: String, id: UUID = UUID()) -> OwnedRuntimeCleanupItem {
        func item(_ status: OwnedRuntimeCleanupStatus, _ reason: String, _ identity: OwnedRuntimeIdentity? = nil,
                  _ receipt: Data? = nil, blocks: Bool = false) -> OwnedRuntimeCleanupItem {
            .init(id: id, status: status, reason: reason, blocksReset: blocks, name: name, identity: identity, receipt: receipt)
        }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return item(.failed, "candidate_unreadable") }
        let identity = OwnedRuntimeIdentity(info)
        guard info.st_mode & S_IFMT == S_IFDIR, identity.uid == expectedUID, info.st_mode & 0o077 == 0 else {
            return item(.manual, "unverified_directory")
        }
        let root = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return item(.failed, "candidate_unreadable", identity) }
        defer { Darwin.close(root) }
        do {
            guard try directoryIdentity(root) == identity else { return item(.changed, "candidate_changed") }
            let data = try manifestData(root)
            let manifest = try JSONDecoder().decode(OwnedRuntimeManifest.self, from: data)
            let prefix = manifest.kind == "chat" ? "claude-deepseek-chat-" : "claude-deepseek-text-"
            guard name.hasPrefix(prefix), manifest.uid == expectedUID,
                  UInt64(manifest.directory_dev) == identity.device, UInt64(manifest.directory_ino) == identity.inode else {
                return item(.manual, "ownership_mismatch", identity)
            }
            if processAlive(manifest.pid) || manifest.native_pid.map({ processAlive($0) || processAlive(-$0) }) == true {
                return item(.active, "owned_process_active", identity, data, blocks: true)
            }
            if manifest.native_state == "pending" {
                return item(.manual, "native_launch_unverified", identity, data, blocks: true)
            }
            return item(.eligible, "owned_inactive", identity, data)
        } catch let failure as OwnedRuntimeCleanupFailure {
            return item(failure == .invalidManifest ? .manual : .failed, failure.rawValue, identity)
        } catch { return item(.manual, "invalid_manifest", identity) }
    }

    private func replacement(_ item: OwnedRuntimeCleanupItem, status: OwnedRuntimeCleanupStatus, reason: String,
                             blocks: Bool = false) -> OwnedRuntimeCleanupItem {
        .init(id: item.id, status: status, reason: reason, blocksReset: blocks,
              name: item.name, identity: item.identity, receipt: item.receipt)
    }

    private func isCandidate(_ name: String) -> Bool {
        name.range(of: "^claude-deepseek-(?:chat|text)-(?:[A-Za-z0-9]{6}|cleanup-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$",
                   options: .regularExpression) != nil
    }

    private func openParent() throws -> Int32 {
        let root: URL
        if let tempRoot { root = tempRoot }
        else { root = try Self.defaultTemporaryRoot() }
        guard root.isFileURL, root.path.hasPrefix("/") else { throw OwnedRuntimeCleanupFailure.invalidDirectory }
        let components = root.path.split(separator: "/").map(String.init)
        guard !components.contains(".."), !components.contains(".") else { throw OwnedRuntimeCleanupFailure.invalidDirectory }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw OwnedRuntimeCleanupFailure.scanUnavailable }
        for component in components {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(descriptor)
            guard next >= 0 else { throw OwnedRuntimeCleanupFailure.scanUnavailable }
            descriptor = next
        }
        do {
            let identity = try directoryIdentity(descriptor)
            guard identity.uid == expectedUID else { throw OwnedRuntimeCleanupFailure.invalidDirectory }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }

    private func directoryIdentity(_ descriptor: Int32) throws -> OwnedRuntimeIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw OwnedRuntimeCleanupFailure.invalidDirectory }
        return OwnedRuntimeIdentity(info)
    }

    private func identityAt(_ parent: Int32, _ name: String) -> OwnedRuntimeIdentity? {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return OwnedRuntimeIdentity(info)
    }

    private func manifestData(_ descriptor: Int32) throws -> Data {
        let file = openat(descriptor, Self.manifestName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw OwnedRuntimeCleanupFailure.invalidManifest }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == expectedUID,
              info.st_mode & 0o077 == 0, info.st_nlink == 1, info.st_size > 0, info.st_size <= 4096 else {
            throw OwnedRuntimeCleanupFailure.invalidManifest
        }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
        guard count == info.st_size else { throw OwnedRuntimeCleanupFailure.invalidManifest }
        var extra: UInt8 = 0
        guard Darwin.read(file, &extra, 1) == 0 else { throw OwnedRuntimeCleanupFailure.invalidManifest }
        return data
    }

    private func entries(_ descriptor: Int32) throws -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0 else { throw OwnedRuntimeCleanupFailure.scanUnavailable }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw OwnedRuntimeCleanupFailure.scanUnavailable }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw OwnedRuntimeCleanupFailure.scanUnavailable }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
            guard result.count <= 20_000 else { throw OwnedRuntimeCleanupFailure.limitExceeded }
        }
        return result.sorted()
    }

    private func removeContents(_ descriptor: Int32, rootIdentity: OwnedRuntimeIdentity, depth: Int, budget: inout Int) throws {
        guard depth <= 32 else { throw OwnedRuntimeCleanupFailure.limitExceeded }
        for name in try entries(descriptor) where depth != 0 || name != Self.manifestName {
            budget -= 1
            guard budget >= 0 else { throw OwnedRuntimeCleanupFailure.limitExceeded }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw OwnedRuntimeCleanupFailure.directoryChanged }
            let identity = OwnedRuntimeIdentity(info)
            guard identity.uid == expectedUID, identity.device == rootIdentity.device else { throw OwnedRuntimeCleanupFailure.unsafeEntry }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw OwnedRuntimeCleanupFailure.directoryChanged }
                defer { Darwin.close(child) }
                guard try directoryIdentity(child) == identity else { throw OwnedRuntimeCleanupFailure.directoryChanged }
                try removeContents(child, rootIdentity: rootIdentity, depth: depth + 1, budget: &budget)
                guard identityAt(descriptor, name) == identity,
                      unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { throw OwnedRuntimeCleanupFailure.deletionFailed }
            } else {
                // unlinkat removes a symlink itself; it never follows its target.
                guard identityAt(descriptor, name) == identity, unlinkat(descriptor, name, 0) == 0 else {
                    throw OwnedRuntimeCleanupFailure.deletionFailed
                }
            }
        }
    }
}
