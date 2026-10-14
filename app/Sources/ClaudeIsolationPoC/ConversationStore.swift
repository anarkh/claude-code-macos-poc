import Darwin
import Foundation

enum ConversationRole: String, Codable, Sendable {
    case user, assistant, activity
}

enum ConversationMessageState: String, Codable, Sendable {
    case translating, running, streaming, complete, failed, cancelled
}

struct ConversationMessage: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var role: ConversationRole
    var text: String
    var originalText: String?
    var translation: String?
    var state: ConversationMessageState
    var error: String?
    var createdAt: Date
    var runID: UUID?
    var requestTraces: [ChatRequestTrace]?

    init(id: UUID = UUID(), role: ConversationRole, text: String,
         originalText: String? = nil, translation: String? = nil,
         state: ConversationMessageState = .complete, error: String? = nil,
         createdAt: Date = Date(), runID: UUID? = nil, requestTraces: [ChatRequestTrace]? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.originalText = originalText
        self.translation = translation
        self.state = state
        self.error = error
        self.createdAt = createdAt
        self.runID = runID
        self.requestTraces = requestTraces
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, role, text, originalText, translation, state, error, createdAt, runID, requestTraces
    }

    init(from decoder: any Decoder) throws {
        try checkConversationFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(ConversationRole.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        originalText = try values.decodeIfPresent(String.self, forKey: .originalText)
        translation = try values.decodeIfPresent(String.self, forKey: .translation)
        state = try values.decode(ConversationMessageState.self, forKey: .state)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        runID = try values.decodeIfPresent(UUID.self, forKey: .runID)
        requestTraces = try values.decodeIfPresent([ChatRequestTrace].self, forKey: .requestTraces)
    }
}

struct ConversationRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var draft: String
    var targetLanguage: String
    var messages: [ConversationMessage]

    init(id: UUID = UUID(), title: String = "新会话", createdAt: Date = Date(),
         updatedAt: Date = Date(), draft: String = "", targetLanguage: String = "en",
         messages: [ConversationMessage] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.draft = draft
        self.targetLanguage = targetLanguage
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, title, createdAt, updatedAt, draft, targetLanguage, messages
    }

    init(from decoder: any Decoder) throws {
        try checkConversationFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        draft = try values.decode(String.self, forKey: .draft)
        targetLanguage = try values.decode(String.self, forKey: .targetLanguage)
        messages = try values.decode([ConversationMessage].self, forKey: .messages)
    }
}

struct ConversationSnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var selectedID: UUID?
    var conversations: [ConversationRecord]

    static let empty = ConversationSnapshot()

    init(schemaVersion: Int = 1, selectedID: UUID? = nil, conversations: [ConversationRecord] = []) {
        self.schemaVersion = schemaVersion
        self.selectedID = selectedID
        self.conversations = conversations
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, selectedID, conversations
    }

    init(from decoder: any Decoder) throws {
        try checkConversationFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else { throw ConversationStoreFailure.unsupportedVersion }
        selectedID = try values.decodeIfPresent(UUID.self, forKey: .selectedID)
        conversations = try values.decode([ConversationRecord].self, forKey: .conversations)
        try validate()
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw ConversationStoreFailure.unsupportedVersion }
        var conversationIDs = Set<UUID>()
        var messageIDs = Set<UUID>()
        var seenRunIDs = Set<UUID>()
        for conversation in conversations {
            guard conversationIDs.insert(conversation.id).inserted else {
                throw ConversationStoreFailure.duplicateConversationID
            }
            guard ["en", "ja"].contains(conversation.targetLanguage) else {
                throw ConversationStoreFailure.invalidLanguage
            }
            guard conversation.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  conversation.updatedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw ConversationStoreFailure.invalidFormat
            }
            var runUsers = Set<UUID>()
            var runAssistants = Set<UUID>()
            for message in conversation.messages {
                guard messageIDs.insert(message.id).inserted else {
                    throw ConversationStoreFailure.duplicateMessageID
                }
                guard message.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                    throw ConversationStoreFailure.invalidFormat
                }
                if let runID = message.runID {
                    switch message.role {
                    case .user:
                        guard runUsers.insert(runID).inserted, message.requestTraces == nil,
                              seenRunIDs.insert(runID).inserted else { throw ConversationStoreFailure.invalidFormat }
                    case .assistant:
                        guard runUsers.contains(runID), runAssistants.insert(runID).inserted else { throw ConversationStoreFailure.invalidFormat }
                    case .activity: throw ConversationStoreFailure.invalidFormat
                    }
                } else if message.requestTraces != nil { throw ConversationStoreFailure.invalidFormat }
                if let traces = message.requestTraces {
                    guard message.role == .assistant, let runID = message.runID, traces.count <= 3 else {
                        throw ConversationStoreFailure.invalidFormat
                    }
                    for (index, trace) in traces.enumerated() {
                        guard trace.attempt == index + 1,
                              index == traces.count - 1 || trace.phase != .request else { throw ConversationStoreFailure.invalidFormat }
                        do { try trace.validate(runID: runID) }
                        catch { throw ConversationStoreFailure.invalidFormat }
                    }
                }
            }
        }
        guard selectedID.map({ conversationIDs.contains($0) }) ?? true else {
            throw ConversationStoreFailure.invalidSelection
        }
    }
}

enum ConversationStoreFailure: Error, Equatable, Sendable {
    case unsupportedVersion, invalidFormat, duplicateConversationID, duplicateMessageID
    case invalidSelection, invalidLanguage, tooLarge, readFailed, saveFailed, cleanupFailed

    var message: String {
        switch self {
        case .unsupportedVersion: "会话文件版本不受支持。请保留原文件并使用支持该版本的应用打开。"
        case .invalidFormat: "会话文件格式无效，原文件已保留。请检查文件或从备份恢复。"
        case .duplicateConversationID: "会话文件包含重复的会话编号，原文件已保留。请从备份恢复。"
        case .duplicateMessageID: "会话文件包含重复的消息编号，原文件已保留。请从备份恢复。"
        case .invalidSelection: "会话文件选中的会话不存在，原文件已保留。请从备份恢复。"
        case .invalidLanguage: "会话的输入翻译语言无效，原文件已保留。请选择英语或日语。"
        case .tooLarge: "会话文件超过 16 MiB，无法保存或读取。请先备份并减少会话内容。"
        case .readFailed: "会话文件无法读取。请检查应用数据目录的权限。"
        case .saveFailed: "会话未能保存。请检查应用数据目录的权限与可用空间后重试。"
        case .cleanupFailed: "会话保存失败，临时文件未能清理。请检查应用数据目录的权限后重试。"
        }
    }
}

protocol ConversationPersisting {
    func load() throws -> ConversationSnapshot
    func save(_ snapshot: ConversationSnapshot) throws
}

struct FileConversationStore: ConversationPersisting {
    static let maximumBytes = 16 * 1_024 * 1_024
    let fileURL: URL
    private let atomicReplace: (URL, URL) throws -> Void

    init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudeIsolationPoC", isDirectory: true)
        .appendingPathComponent("conversations.json"),
         atomicReplace: @escaping (URL, URL) throws -> Void = { temporary, destination in
             guard Darwin.rename(temporary.path, destination.path) == 0 else {
                 throw ConversationStoreFailure.saveFailed
             }
         }) {
        self.fileURL = fileURL
        self.atomicReplace = atomicReplace
    }

    func load() throws -> ConversationSnapshot {
        guard fileURL.isFileURL else { throw ConversationStoreFailure.readFailed }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return .empty
        } catch {
            throw ConversationStoreFailure.readFailed
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ConversationStoreFailure.readFailed
        }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= Self.maximumBytes else {
            throw ConversationStoreFailure.tooLarge
        }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            do { data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data() }
            catch {
                do { try handle.close() }
                catch { throw ConversationStoreFailure.readFailed }
                throw ConversationStoreFailure.readFailed
            }
            try handle.close()
        } catch { throw ConversationStoreFailure.readFailed }
        guard data.count <= Self.maximumBytes else { throw ConversationStoreFailure.tooLarge }
        do { return try JSONDecoder().decode(ConversationSnapshot.self, from: data) }
        catch let error as ConversationStoreFailure { throw error }
        catch { throw ConversationStoreFailure.invalidFormat }
    }

    func save(_ snapshot: ConversationSnapshot) throws {
        guard fileURL.isFileURL else { throw ConversationStoreFailure.saveFailed }
        try snapshot.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(snapshot) }
        catch { throw ConversationStoreFailure.invalidFormat }
        guard data.count <= Self.maximumBytes else { throw ConversationStoreFailure.tooLarge }
        // A broken or newer file is never replaced by a newly initialized session.
        _ = try load()
        let folder = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } catch { throw ConversationStoreFailure.saveFailed }
        let temporary = folder.appendingPathComponent(".conversations-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ConversationStoreFailure.saveFailed }
        var descriptorOpen = true
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { throw ConversationStoreFailure.saveFailed }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw ConversationStoreFailure.saveFailed }
                    offset += written
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw ConversationStoreFailure.saveFailed }
            let closed = Darwin.close(descriptor)
            descriptorOpen = false
            guard closed == 0 else { throw ConversationStoreFailure.saveFailed }
            try atomicReplace(temporary, fileURL)
        } catch {
            let closeFailed = descriptorOpen && Darwin.close(descriptor) != 0
            let removeFailed = Darwin.unlink(temporary.path) != 0 && errno != ENOENT
            if closeFailed || removeFailed { throw ConversationStoreFailure.cleanupFailed }
            throw ConversationStoreFailure.saveFailed
        }
    }
}

private struct ConversationCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func checkConversationFields(_ decoder: any Decoder, allowed: [String]) throws {
    let fields = try decoder.container(keyedBy: ConversationCodingKey.self)
    let allowedFields = Set(allowed)
    guard fields.allKeys.allSatisfy({ allowedFields.contains($0.stringValue) }) else {
        throw ConversationStoreFailure.invalidFormat
    }
}
