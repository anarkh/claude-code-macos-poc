import Darwin
import Foundation

enum AppCredentialScope: Equatable, Sendable {
    case translation, execution, subscription

    var filename: String {
        switch self {
        case .translation: "translation-key.json"
        case .execution: "execution-key.json"
        case .subscription: "subscription-token.json"
        }
    }
}

enum LocalCredentialFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidKey, invalidSubscriptionToken, invalidFormat, unsupportedVersion, fileTooLarge
    case readFailed, saveFailed, deleteFailed, cleanupFailed

    var errorDescription: String? { message }

    var message: String {
        switch self {
        case .invalidKey: "API Key 必须为 16–512 字节，不能包含空格、换行或控制字符。请检查后重新保存。"
        case .invalidSubscriptionToken: "请输入 claude setup-token 生成的订阅 Token（sk-ant-oat01- 开头，16–4096 字节，无空格或换行）。"
        case .invalidFormat: "本机 API Key 文件格式无效，原文件已保留。请删除本 App 保存的 API Key 后重新填写，或从备份恢复。"
        case .unsupportedVersion: "本机 API Key 文件版本不受支持，原文件已保留。请使用支持该版本的 App，或删除本 App 保存的 API Key 后重新填写。"
        case .fileTooLarge: "本机 API Key 文件超过 8 KiB，原文件已保留。请删除本 App 保存的 API Key 后重新填写，或从备份恢复。"
        case .readFailed: "无法读取本机 API Key 文件。请检查 App 数据目录权限；文件必须为普通文件，数据目录和文件都不能使用符号链接。"
        case .saveFailed: "API Key 未能保存，原值已保留。请检查 App 数据目录权限和可用空间后重试。"
        case .deleteFailed: "本机 API Key 未能删除，当前值已保留。请检查 App 数据目录权限后重试。"
        case .cleanupFailed: "API Key 保存失败，临时文件未能清理。请检查 App 数据目录权限后重试。"
        }
    }

    var subscriptionMessage: String {
        message.replacingOccurrences(of: "API Key", with: "订阅 Token")
    }

    static func validate(_ key: String) throws {
        guard (16...512).contains(key.utf8.count), !key.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || $0.properties.generalCategory == .control
        }) else { throw LocalCredentialFailure.invalidKey }
    }

    static func validate(_ secret: String, scope: AppCredentialScope) throws {
        guard scope == .subscription else { try validate(secret); return }
        try validateSubscriptionToken(secret)
    }

    static func validateSubscriptionToken(_ secret: String) throws {
        guard (16...4_096).contains(secret.utf8.count), secret.hasPrefix("sk-ant-oat01-"),
              secret.unicodeScalars.allSatisfy({ scalar in
                  (65...90).contains(scalar.value) || (97...122).contains(scalar.value) ||
                  (48...57).contains(scalar.value) || scalar == "-" || scalar == "_"
              }) else { throw LocalCredentialFailure.invalidSubscriptionToken }
    }
}

private struct LocalCredentialSnapshot: Codable {
    let schemaVersion: Int
    let apiKey: String

    init(apiKey: String) { schemaVersion = 1; self.apiKey = apiKey }

    private enum CodingKeys: String, CodingKey { case schemaVersion, apiKey }
    private struct FieldKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: FieldKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == ["schemaVersion", "apiKey"] else {
            throw LocalCredentialFailure.invalidFormat
        }
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
        apiKey = try fields.decode(String.self, forKey: .apiKey)
        guard schemaVersion == 1 else { throw LocalCredentialFailure.unsupportedVersion }
        try LocalCredentialFailure.validate(apiKey)
    }
}

private struct LocalSubscriptionSnapshot: Codable {
    let schemaVersion: Int
    let token: String
    init(token: String) { schemaVersion = 1; self.token = token }

    private enum CodingKeys: String, CodingKey { case schemaVersion, token }
    private struct FieldKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: FieldKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == ["schemaVersion", "token"] else {
            throw LocalCredentialFailure.invalidFormat
        }
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
        token = try fields.decode(String.self, forKey: .token)
        guard schemaVersion == 1 else { throw LocalCredentialFailure.unsupportedVersion }
        try LocalCredentialFailure.validate(token, scope: .subscription)
    }
}

/// Reads the App-owned file once per instance; mutations commit to disk before changing the cache.
final class FileCredentialStore: AppCredentialStoring {
    static let maximumBytes = 8 * 1_024
    static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeIsolationPoC/Credentials", isDirectory: true)
    }

    let directoryURL: URL
    let fileURL: URL
    private let scope: AppCredentialScope
    private let atomicReplace: (URL, URL) throws -> Void
    private enum Cache { case unloaded, loaded(String?) }
    private var cache = Cache.unloaded

    init(scope: AppCredentialScope, directoryURL: URL = FileCredentialStore.defaultDirectoryURL,
         atomicReplace: @escaping (URL, URL) throws -> Void = { temporary, destination in
             guard Darwin.rename(temporary.path, destination.path) == 0 else { throw LocalCredentialFailure.saveFailed }
         }) {
        self.directoryURL = directoryURL
        self.fileURL = directoryURL.appendingPathComponent(scope.filename)
        self.scope = scope
        self.atomicReplace = atomicReplace
    }

    func load() throws -> String? {
        if case .loaded(let key) = cache { return key }
        let key = try readPersistedKey()
        cache = .loaded(key)
        return key
    }

    func save(_ key: String) throws {
        try LocalCredentialFailure.validate(key, scope: scope)
        // Deliberately bypass the cache so a corrupt or newer file is never overwritten.
        _ = try readPersistedKey()
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try scope == .subscription
                ? encoder.encode(LocalSubscriptionSnapshot(token: key))
                : encoder.encode(LocalCredentialSnapshot(apiKey: key))
        }
        catch { throw LocalCredentialFailure.invalidFormat }
        guard data.count <= Self.maximumBytes else { throw LocalCredentialFailure.fileTooLarge }
        let temporary = directoryURL.appendingPathComponent(".credential-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LocalCredentialFailure.saveFailed }
        var descriptorOpen = true
        do {
            guard Darwin.fchmod(descriptor, 0o600) == 0 else { throw LocalCredentialFailure.saveFailed }
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { throw LocalCredentialFailure.saveFailed }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw LocalCredentialFailure.saveFailed }
                    offset += written
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw LocalCredentialFailure.saveFailed }
            let closed = Darwin.close(descriptor)
            descriptorOpen = false
            guard closed == 0 else { throw LocalCredentialFailure.saveFailed }
            try atomicReplace(temporary, fileURL)
            cache = .loaded(key)
        } catch {
            let closeFailed = descriptorOpen && Darwin.close(descriptor) != 0
            let removeFailed = Darwin.unlink(temporary.path) != 0 && errno != ENOENT
            if closeFailed || removeFailed { throw LocalCredentialFailure.cleanupFailed }
            throw LocalCredentialFailure.saveFailed
        }
    }

    func delete() throws {
        do {
            guard try inspectDirectory() else { cache = .loaded(nil); return }
            var metadata = stat()
            if Darwin.lstat(fileURL.path, &metadata) != 0 {
                guard errno == ENOENT else { throw LocalCredentialFailure.deleteFailed }
                cache = .loaded(nil)
                return
            }
            guard metadata.st_mode & S_IFMT == S_IFREG else { throw LocalCredentialFailure.deleteFailed }
            // Explicit deletion also lets the user clear a corrupt regular file before saving again.
            guard Darwin.unlink(fileURL.path) == 0 else { throw LocalCredentialFailure.deleteFailed }
            cache = .loaded(nil)
        } catch { throw LocalCredentialFailure.deleteFailed }
    }

    private func inspectDirectory() throws -> Bool {
        guard directoryURL.isFileURL else { throw LocalCredentialFailure.readFailed }
        var metadata = stat()
        if Darwin.lstat(directoryURL.path, &metadata) != 0 {
            guard errno == ENOENT else { throw LocalCredentialFailure.readFailed }
            return false
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { throw LocalCredentialFailure.readFailed }
        return true
    }

    private func prepareDirectory() throws {
        do {
            if try !inspectDirectory() {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            guard try inspectDirectory(), Darwin.chmod(directoryURL.path, 0o700) == 0 else {
                throw LocalCredentialFailure.saveFailed
            }
        } catch { throw LocalCredentialFailure.saveFailed }
    }

    private func readPersistedKey() throws -> String? {
        guard try inspectDirectory() else { return nil }
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            guard errno == ENOENT else { throw LocalCredentialFailure.readFailed }
            return nil
        }
        var descriptorOpen = true
        do {
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                throw LocalCredentialFailure.readFailed
            }
            guard metadata.st_size >= 0, metadata.st_size <= Self.maximumBytes else { throw LocalCredentialFailure.fileTooLarge }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw LocalCredentialFailure.readFailed }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= Self.maximumBytes else { throw LocalCredentialFailure.fileTooLarge }
            }
            let closed = Darwin.close(descriptor)
            descriptorOpen = false
            guard closed == 0 else { throw LocalCredentialFailure.readFailed }
            do {
                return try scope == .subscription
                    ? JSONDecoder().decode(LocalSubscriptionSnapshot.self, from: data).token
                    : JSONDecoder().decode(LocalCredentialSnapshot.self, from: data).apiKey
            }
            catch let failure as LocalCredentialFailure { throw failure }
            catch { throw LocalCredentialFailure.invalidFormat }
        } catch {
            if descriptorOpen && Darwin.close(descriptor) != 0 { throw LocalCredentialFailure.readFailed }
            throw error
        }
    }
}

/// Fixture-only storage. It never reads a file, Keychain or a model endpoint.
final class MemoryAppCredentialStore: AppCredentialStoring {
    private(set) var key: String?
    private let scope: AppCredentialScope
    var loadFailure: LocalCredentialFailure?
    var saveFailure: LocalCredentialFailure?
    var deleteFailure: LocalCredentialFailure?
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    init(_ key: String? = nil, scope: AppCredentialScope = .execution) { self.key = key; self.scope = scope }

    func load() throws -> String? {
        if let loadFailure { throw loadFailure }
        if let key { try LocalCredentialFailure.validate(key, scope: scope) }
        return key
    }

    func save(_ key: String) throws {
        try LocalCredentialFailure.validate(key, scope: scope)
        if let saveFailure { throw saveFailure }
        self.key = key
        saveCount += 1
    }

    func delete() throws {
        if let deleteFailure { throw deleteFailure }
        key = nil
        deleteCount += 1
    }
}
