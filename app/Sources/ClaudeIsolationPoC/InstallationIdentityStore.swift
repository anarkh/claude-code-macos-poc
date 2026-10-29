import CryptoKit
import CoreFoundation
import Darwin
import Foundation

/// Installation identity is random application state, never a hardware identifier
/// or a derivative of a credential. A conversation supplies its own session ID.
struct ClaudeRequestIdentity: Codable, Equatable, Sendable {
    let device_id: String
    let session_id: String

    func validate() throws {
        guard Self.validDeviceID(device_id), UUID(uuidString: session_id) != nil else {
            throw InstallationIdentityFailure.invalidFormat
        }
    }

    static func validDeviceID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

enum InstallationIdentityFailure: Error, LocalizedError, Sendable {
    case invalidFormat, unsupportedVersion, readFailed, saveFailed, replacementFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat, .unsupportedVersion:
            "本机设备身份文件格式无效或版本不受支持。原文件已保留，请恢复备份或使用支持该版本的 App。"
        case .readFailed:
            "无法读取本机设备身份，请检查 App 数据目录的访问权限。"
        case .saveFailed:
            "无法保存本机设备身份，本次请求未发送。请检查磁盘空间和 App 数据目录权限。"
        case .replacementFailed:
            "无法确认设备身份已完成更换。请重新读取当前设备身份，并检查磁盘空间和 App 数据目录权限。"
        }
    }
}

protocol InstallationIdentityProviding: Sendable {
    func loadOrCreateDeviceID() throws -> String
}

protocol InstallationIdentityManaging: InstallationIdentityProviding {
    func loadDeviceID() throws -> String?
    func replaceDeviceID() throws -> String
}

struct FileInstallationIdentityStore: InstallationIdentityManaging {
    static var defaultDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeIsolationPoC/Identity", isDirectory: true)
    }

    let directoryURL: URL
    var fileURL: URL { directoryURL.appendingPathComponent("installation.json") }

    init(directoryURL: URL = Self.defaultDirectoryURL) { self.directoryURL = directoryURL }

    func loadDeviceID() throws -> String? { try read() }

    func loadOrCreateDeviceID() throws -> String {
        if let existing = try read() { return existing }
        try prepareDirectory()
        return try withTemporaryIdentityFile(deviceID: Self.randomDeviceID()) { temporary in
            // Publish a complete file without replacing another process's identity.
            guard Darwin.link(temporary.path, fileURL.path) == 0 || errno == EEXIST else {
                throw InstallationIdentityFailure.saveFailed
            }
            guard Darwin.unlink(temporary.path) == 0 else { throw InstallationIdentityFailure.saveFailed }
            guard let saved = try read() else { throw InstallationIdentityFailure.saveFailed }
            return saved
        }
    }

    func replaceDeviceID() throws -> String {
        // Read and validate before touching the identity. Invalid or newer data
        // must remain available for recovery, including when rotation is explicit.
        let previous = try read()
        do {
            try prepareDirectory()
            var deviceID = Self.randomDeviceID()
            while deviceID == previous { deviceID = Self.randomDeviceID() }
            return try withTemporaryIdentityFile(deviceID: deviceID) { temporary in
                guard Darwin.rename(temporary.path, fileURL.path) == 0 else {
                    throw InstallationIdentityFailure.replacementFailed
                }
                guard try read() == deviceID else { throw InstallationIdentityFailure.replacementFailed }
                return deviceID
            }
        } catch {
            // A readback or cleanup error may occur after rename succeeded. Do
            // not claim that the previous identity is still stored on failure.
            throw InstallationIdentityFailure.replacementFailed
        }
    }

    private static func randomDeviceID() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    private func prepareDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directoryURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        } catch { throw InstallationIdentityFailure.saveFailed }
        // mkdir applies the private mode atomically. Foundation may create the
        // directory before applying attributes, exposing an intermediate mode
        // to a concurrent first-use reader.
        guard Darwin.mkdir(directoryURL.path, 0o700) == 0 || errno == EEXIST else {
            throw InstallationIdentityFailure.saveFailed
        }
        guard try inspectDirectory() else { throw InstallationIdentityFailure.saveFailed }
    }

    private func withTemporaryIdentityFile(deviceID: String, publish: (URL) throws -> String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "deviceID": deviceID], options: [.sortedKeys])
        let temporary = directoryURL.appendingPathComponent(".installation-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw InstallationIdentityFailure.saveFailed }
        var descriptorOpen = true
        do {
            guard Darwin.fchmod(descriptor, 0o600) == 0 else { throw InstallationIdentityFailure.saveFailed }
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { throw InstallationIdentityFailure.saveFailed }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw InstallationIdentityFailure.saveFailed }
                    offset += count
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw InstallationIdentityFailure.saveFailed }
            let closeResult = Darwin.close(descriptor)
            descriptorOpen = false
            guard closeResult == 0 else { throw InstallationIdentityFailure.saveFailed }
            return try publish(temporary)
        } catch {
            let closeFailed = descriptorOpen && Darwin.close(descriptor) != 0
            let cleanupFailed = Darwin.unlink(temporary.path) != 0 && errno != ENOENT
            if closeFailed || cleanupFailed { throw InstallationIdentityFailure.saveFailed }
            throw error
        }
    }

    private func inspectDirectory() throws -> Bool {
        guard directoryURL.isFileURL else { throw InstallationIdentityFailure.readFailed }
        var metadata = stat()
        if Darwin.lstat(directoryURL.path, &metadata) != 0 {
            guard errno == ENOENT else { throw InstallationIdentityFailure.readFailed }
            return false
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0 else { throw InstallationIdentityFailure.readFailed }
        return true
    }

    private func read() throws -> String? {
        guard try inspectDirectory() else { return nil }
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            guard errno == ENOENT else { throw InstallationIdentityFailure.readFailed }
            return nil
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0,
              metadata.st_size > 0, metadata.st_size <= 1_024 else { throw InstallationIdentityFailure.readFailed }
        var bytes = [UInt8](repeating: 0, count: 1_025)
        var count = 0
        while count < bytes.count {
            let readCount = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
            }
            if readCount < 0 && errno == EINTR { continue }
            guard readCount >= 0 else { throw InstallationIdentityFailure.readFailed }
            if readCount == 0 { break }
            count += readCount
        }
        guard count == Int(metadata.st_size),
              let fields = try? JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any],
              Set(fields.keys) == ["schemaVersion", "deviceID"],
              let version = fields["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let deviceID = fields["deviceID"] as? String, ClaudeRequestIdentity.validDeviceID(deviceID)
        else { throw InstallationIdentityFailure.invalidFormat }
        return deviceID
    }
}

struct FixtureInstallationIdentityStore: InstallationIdentityProviding {
    let deviceID: String
    init(deviceID: String = String(repeating: "a", count: 64)) { self.deviceID = deviceID }
    func loadOrCreateDeviceID() throws -> String {
        guard ClaudeRequestIdentity.validDeviceID(deviceID) else { throw InstallationIdentityFailure.invalidFormat }
        return deviceID
    }
}
