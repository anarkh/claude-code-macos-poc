import Darwin
import Foundation

enum SubscriptionAccountStoreFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidFormat, unsupportedVersion, invalidLabel, tooManyAccounts, fileTooLarge
    case readFailed, saveFailed, cleanupFailed, readbackFailed, migrationFailed

    var errorDescription: String? { message }

    var message: String {
        switch self {
        case .invalidFormat: "本机订阅账号文件格式无效，原文件已保留。请从备份恢复，不会自动改用旧 Token。"
        case .unsupportedVersion: "本机订阅账号文件版本不受支持，原文件已保留。请使用支持该版本的 App。"
        case .invalidLabel: "账号名称须为 1–80 个字符，不能包含首尾空白或控制字符。"
        case .tooManyAccounts: "最多保存 32 个订阅账号。请先删除不再使用的账号。"
        case .fileTooLarge: "本机订阅账号文件超过 256 KiB，原文件已保留。请从备份恢复。"
        case .readFailed: "无法读取本机订阅账号文件。请检查数据目录权限；目录和文件不能使用符号链接。"
        case .saveFailed: "订阅账号未能保存。请检查数据目录权限和可用空间后重试。"
        case .cleanupFailed: "订阅账号保存失败，临时文件未能清理。请检查数据目录权限后重试。"
        case .readbackFailed: "订阅账号保存后校验未通过。请重新读取账号状态，或从备份恢复后重试。"
        case .migrationFailed: "无法迁移原有订阅 Token，原文件已保留。请检查原凭据文件和数据目录权限。"
        }
    }
}

private struct SubscriptionAccountFieldKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

struct SubscriptionAccount: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var label: String
    var token: String?
    var credentialVersion: UUID

    init(id: UUID = UUID(), label: String, token: String?, credentialVersion: UUID = UUID()) {
        self.id = id
        self.label = label
        self.token = token
        self.credentialVersion = credentialVersion
    }

    func validate() throws {
        guard !label.isEmpty, label.count <= 80, label.utf8.count <= 1_024,
              label == label.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw SubscriptionAccountStoreFailure.invalidLabel
        }
        if let token { try LocalCredentialFailure.validateSubscriptionToken(token) }
    }

    private enum CodingKeys: String, CodingKey { case id, label, token, credentialVersion }

    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: SubscriptionAccountFieldKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == ["id", "label", "token", "credentialVersion"] else {
            throw SubscriptionAccountStoreFailure.invalidFormat
        }
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(UUID.self, forKey: .id)
        label = try fields.decode(String.self, forKey: .label)
        token = try fields.decodeIfPresent(String.self, forKey: .token)
        credentialVersion = try fields.decode(UUID.self, forKey: .credentialVersion)
        try validate()
    }

    func encode(to encoder: any Encoder) throws {
        try validate()
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(id, forKey: .id)
        try fields.encode(label, forKey: .label)
        try fields.encode(token, forKey: .token)
        try fields.encode(credentialVersion, forKey: .credentialVersion)
    }
}

struct SubscriptionAccountCatalog: Codable, Equatable, Sendable {
    static let maximumAccounts = 32
    var schemaVersion: Int
    var currentAccountID: UUID?
    var accounts: [SubscriptionAccount]

    init(schemaVersion: Int = 1, currentAccountID: UUID? = nil, accounts: [SubscriptionAccount] = []) {
        self.schemaVersion = schemaVersion
        self.currentAccountID = currentAccountID
        self.accounts = accounts
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw SubscriptionAccountStoreFailure.unsupportedVersion }
        guard accounts.count <= Self.maximumAccounts else { throw SubscriptionAccountStoreFailure.tooManyAccounts }
        guard Set(accounts.map(\.id)).count == accounts.count,
              currentAccountID == nil || accounts.contains(where: { $0.id == currentAccountID }) else {
            throw SubscriptionAccountStoreFailure.invalidFormat
        }
        try accounts.forEach { try $0.validate() }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, currentAccountID, accounts }

    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: SubscriptionAccountFieldKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == ["schemaVersion", "currentAccountID", "accounts"] else {
            throw SubscriptionAccountStoreFailure.invalidFormat
        }
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else { throw SubscriptionAccountStoreFailure.unsupportedVersion }
        currentAccountID = try fields.decodeIfPresent(UUID.self, forKey: .currentAccountID)
        accounts = try fields.decode([SubscriptionAccount].self, forKey: .accounts)
        try validate()
    }

    func encode(to encoder: any Encoder) throws {
        try validate()
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(schemaVersion, forKey: .schemaVersion)
        try fields.encode(currentAccountID, forKey: .currentAccountID)
        try fields.encode(accounts, forKey: .accounts)
    }
}

protocol SubscriptionAccountStoring: AnyObject {
    func load() throws -> SubscriptionAccountCatalog
    func save(_ catalog: SubscriptionAccountCatalog) throws
}

/// One atomic vault keeps account selection and credentials consistent. The old
/// single-token file is a migration source only and is never updated by this store.
final class FileSubscriptionAccountStore: SubscriptionAccountStoring {
    static let maximumBytes = 256 * 1_024
    let directoryURL: URL
    let fileURL: URL
    private let legacyCredentials: any AppCredentialStoring
    private let atomicReplace: (URL, URL) throws -> Void

    init(directoryURL: URL = FileCredentialStore.defaultDirectoryURL,
         legacyCredentials: (any AppCredentialStoring)? = nil,
         atomicReplace: @escaping (URL, URL) throws -> Void = { temporary, destination in
             guard Darwin.rename(temporary.path, destination.path) == 0 else {
                 throw SubscriptionAccountStoreFailure.saveFailed
             }
         }) {
        self.directoryURL = directoryURL
        fileURL = directoryURL.appendingPathComponent("subscription-accounts.json")
        self.legacyCredentials = legacyCredentials ?? FileCredentialStore(scope: .subscription, directoryURL: directoryURL)
        self.atomicReplace = atomicReplace
    }

    func load() throws -> SubscriptionAccountCatalog {
        if let catalog = try readPersistedCatalog() { return catalog }
        let token: String?
        do { token = try legacyCredentials.load() }
        catch { throw SubscriptionAccountStoreFailure.migrationFailed }
        let catalog: SubscriptionAccountCatalog
        if let token {
            let account = SubscriptionAccount(label: "默认账号", token: token)
            catalog = .init(currentAccountID: account.id, accounts: [account])
        } else { catalog = .init() }
        // Persist even an empty catalog so deleting an authorization cannot later
        // resurrect the legacy Token through an implicit fallback.
        try save(catalog)
        guard let persisted = try readPersistedCatalog(), persisted == catalog else {
            throw SubscriptionAccountStoreFailure.readbackFailed
        }
        return persisted
    }

    func save(_ catalog: SubscriptionAccountCatalog) throws {
        try catalog.validate()
        // Reopen on every write: a corrupt or newer vault must never be overwritten.
        _ = try readPersistedCatalog()
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(catalog) }
        catch let failure as SubscriptionAccountStoreFailure { throw failure }
        catch let failure as LocalCredentialFailure { throw failure }
        catch { throw SubscriptionAccountStoreFailure.invalidFormat }
        guard data.count <= Self.maximumBytes else { throw SubscriptionAccountStoreFailure.fileTooLarge }
        let temporary = directoryURL.appendingPathComponent(".subscription-accounts-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SubscriptionAccountStoreFailure.saveFailed }
        var descriptorOpen = true
        do {
            guard Darwin.fchmod(descriptor, 0o600) == 0 else { throw SubscriptionAccountStoreFailure.saveFailed }
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { throw SubscriptionAccountStoreFailure.saveFailed }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw SubscriptionAccountStoreFailure.saveFailed }
                    offset += written
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw SubscriptionAccountStoreFailure.saveFailed }
            let closed = Darwin.close(descriptor)
            descriptorOpen = false
            guard closed == 0 else { throw SubscriptionAccountStoreFailure.saveFailed }
            try atomicReplace(temporary, fileURL)
        } catch {
            let closeFailed = descriptorOpen && Darwin.close(descriptor) != 0
            let removeFailed = Darwin.unlink(temporary.path) != 0 && errno != ENOENT
            if closeFailed || removeFailed { throw SubscriptionAccountStoreFailure.cleanupFailed }
            throw SubscriptionAccountStoreFailure.saveFailed
        }
        do {
            guard try readPersistedCatalog() == catalog else {
                throw SubscriptionAccountStoreFailure.readbackFailed
            }
        } catch {
            let removeFailed = Darwin.unlink(temporary.path) != 0 && errno != ENOENT
            if removeFailed { throw SubscriptionAccountStoreFailure.cleanupFailed }
            throw SubscriptionAccountStoreFailure.readbackFailed
        }
        let removeFailed = Darwin.unlink(temporary.path) != 0 && errno != ENOENT
        if removeFailed { throw SubscriptionAccountStoreFailure.cleanupFailed }
    }

    private func inspectDirectory() throws -> Bool {
        guard directoryURL.isFileURL else { throw SubscriptionAccountStoreFailure.readFailed }
        var metadata = stat()
        if Darwin.lstat(directoryURL.path, &metadata) != 0 {
            guard errno == ENOENT else { throw SubscriptionAccountStoreFailure.readFailed }
            return false
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { throw SubscriptionAccountStoreFailure.readFailed }
        return true
    }

    private func prepareDirectory() throws {
        do {
            if try !inspectDirectory() {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            guard try inspectDirectory(), Darwin.chmod(directoryURL.path, 0o700) == 0 else {
                throw SubscriptionAccountStoreFailure.saveFailed
            }
        } catch { throw SubscriptionAccountStoreFailure.saveFailed }
    }

    private func readPersistedCatalog() throws -> SubscriptionAccountCatalog? {
        guard try inspectDirectory() else { return nil }
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            guard errno == ENOENT else { throw SubscriptionAccountStoreFailure.readFailed }
            return nil
        }
        var descriptorOpen = true
        do {
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                throw SubscriptionAccountStoreFailure.readFailed
            }
            guard metadata.st_size >= 0, metadata.st_size <= Self.maximumBytes else {
                throw SubscriptionAccountStoreFailure.fileTooLarge
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw SubscriptionAccountStoreFailure.readFailed }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= Self.maximumBytes else { throw SubscriptionAccountStoreFailure.fileTooLarge }
            }
            let closed = Darwin.close(descriptor)
            descriptorOpen = false
            guard closed == 0 else { throw SubscriptionAccountStoreFailure.readFailed }
            do { return try JSONDecoder().decode(SubscriptionAccountCatalog.self, from: data) }
            catch let failure as SubscriptionAccountStoreFailure { throw failure }
            catch let failure as LocalCredentialFailure { throw failure }
            catch { throw SubscriptionAccountStoreFailure.invalidFormat }
        } catch {
            if descriptorOpen && Darwin.close(descriptor) != 0 { throw SubscriptionAccountStoreFailure.readFailed }
            throw error
        }
    }
}

/// Fixture-only storage; never reads an account, credential file, or network endpoint.
final class MemorySubscriptionAccountStore: SubscriptionAccountStoring {
    private(set) var catalog: SubscriptionAccountCatalog
    private(set) var saveCount = 0
    var loadFailure: SubscriptionAccountStoreFailure?
    var saveFailure: SubscriptionAccountStoreFailure?

    init(catalog: SubscriptionAccountCatalog = .init()) { self.catalog = catalog }

    func load() throws -> SubscriptionAccountCatalog {
        if let loadFailure { throw loadFailure }
        try catalog.validate()
        return catalog
    }

    func save(_ catalog: SubscriptionAccountCatalog) throws {
        try catalog.validate()
        if let saveFailure { throw saveFailure }
        self.catalog = catalog
        saveCount += 1
    }
}
