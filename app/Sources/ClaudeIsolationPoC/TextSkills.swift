import Combine
import Darwin
import Foundation

struct TextSkill: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var summary: String
    var content: String
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, summary: String = "", content: String,
         isEnabled: Bool = false) {
        self.id = id
        self.name = name
        self.summary = summary
        self.content = content
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, summary, content, isEnabled
    }

    init(from decoder: any Decoder) throws {
        try textSkillsCheckFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(UUID.self, forKey: .id)
        name = try fields.decode(String.self, forKey: .name)
        summary = try fields.decode(String.self, forKey: .summary)
        content = try fields.decode(String.self, forKey: .content)
        isEnabled = try fields.decode(Bool.self, forKey: .isEnabled)
    }
}

struct TextSkillContext: Codable, Equatable, Sendable {
    var name: String
    var content: String
}

enum TextSkillFailure: Error, Equatable, LocalizedError, Sendable {
    case unsupportedVersion, invalidFormat, duplicateID, duplicateName, invalidName, invalidSummary
    case emptyContent, contentTooLarge, tooManySkills, tooManyEnabled, contextTooLarge
    case invalidSelection, unreadableImport, nonUTF8, importTooLarge, invalidFrontmatter
    case readFailed, fileTooLarge, saveFailed, cleanupFailed, unknownSkill

    var errorDescription: String? { message }

    var message: String {
        switch self {
        case .unsupportedVersion: "Skills 文件版本不受支持。原文件已保留，请使用支持该版本的应用打开。"
        case .invalidFormat: "Skills 文件格式无效。原文件已保留，请检查文件或从备份恢复后重新打开应用。"
        case .duplicateID: "Skills 文件包含重复编号。原文件已保留，请检查文件或从备份恢复。"
        case .duplicateName: "已存在同名 Skill，原 App 副本已保留。如需更新，请先移除该副本，再重新导入。"
        case .invalidName: "Skill 名称必须为 1–80 个字符，不能包含换行或控制字符。请检查 SKILL.md 的 name。"
        case .invalidSummary: "Skill 描述超过 600 个字符。请缩短 SKILL.md 的 description 后重试。"
        case .emptyContent: "SKILL.md 正文为空。请在元数据之后添加文本指令。"
        case .contentTooLarge: "Skill 正文超过 32 KiB。请减少正文内容后再导入。"
        case .tooManySkills: "最多保存 32 个 Skills。请先移除不需要的 App 副本。"
        case .tooManyEnabled: "最多同时启用 8 个 Skills。请先停用其他 Skills。"
        case .contextTooLarge: "启用的 Skills 文本总量超过 64 KiB。请停用部分 Skills 或减少正文内容。"
        case .invalidSelection: "请选择名为 SKILL.md 的文件，或直接包含该文件的文件夹。"
        case .unreadableImport: "SKILL.md 无法读取。请检查文件是否存在、是否为普通文件及读取权限。"
        case .nonUTF8: "SKILL.md 不是有效的 UTF-8 文本。请另存为 UTF-8 后重试。"
        case .importTooLarge: "SKILL.md 文件超过 64 KiB。请减少元数据和正文后重试。"
        case .invalidFrontmatter: "SKILL.md 元数据格式无效。name 和 description 可使用普通文本、引号或 | / > 块文本；请检查引号与 --- 分隔线。"
        case .readFailed: "Skills 文件无法读取。请检查应用数据目录的权限；原文件不会被覆盖。"
        case .fileTooLarge: "Skills 文件超过 8 MiB。原文件已保留，请从备份恢复有效文件。"
        case .saveFailed: "Skills 未能保存。请检查应用数据目录权限和可用空间后重试。"
        case .cleanupFailed: "Skills 保存失败，临时文件未能清理。请检查应用数据目录权限后重试。"
        case .unknownSkill: "该 Skill 已不存在。请重新选择列表中的 Skill。"
        }
    }
}

struct TextSkillsSnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var skills: [TextSkill]

    static let empty = TextSkillsSnapshot()
    static let maximumSkills = 32
    static let maximumEnabled = 8
    static let maximumContentBytes = 32_768
    static let maximumContextBytes = 65_536

    init(schemaVersion: Int = 1, skills: [TextSkill] = []) {
        self.schemaVersion = schemaVersion
        self.skills = skills
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, skills }

    init(from decoder: any Decoder) throws {
        try textSkillsCheckFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
        skills = try fields.decode([TextSkill].self, forKey: .skills)
        try validate()
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw TextSkillFailure.unsupportedVersion }
        guard skills.count <= Self.maximumSkills else { throw TextSkillFailure.tooManySkills }
        var IDs = Set<UUID>()
        var names = Set<String>()
        var enabledCount = 0
        var contextBytes = 0
        for skill in skills {
            guard IDs.insert(skill.id).inserted else { throw TextSkillFailure.duplicateID }
            let trimmedName = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard skill.name == trimmedName, !trimmedName.isEmpty, skill.name.unicodeScalars.count <= 80,
                  !skill.name.unicodeScalars.contains(where: {
                      $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
                  }) else {
                throw TextSkillFailure.invalidName
            }
            let normalizedName = skill.name.precomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(normalizedName).inserted else { throw TextSkillFailure.duplicateName }
            guard skill.summary.count <= 600 else { throw TextSkillFailure.invalidSummary }
            guard !skill.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TextSkillFailure.emptyContent
            }
            guard skill.content.utf8.count <= Self.maximumContentBytes else {
                throw TextSkillFailure.contentTooLarge
            }
            if skill.isEnabled {
                enabledCount += 1
                contextBytes += skill.name.utf8.count + skill.content.utf8.count
            }
        }
        guard enabledCount <= Self.maximumEnabled else { throw TextSkillFailure.tooManyEnabled }
        guard contextBytes <= Self.maximumContextBytes else { throw TextSkillFailure.contextTooLarge }
    }
}

protocol TextSkillPersisting {
    func load() throws -> TextSkillsSnapshot
    func save(_ snapshot: TextSkillsSnapshot) throws
}

struct FileTextSkillStore: TextSkillPersisting {
    static let maximumBytes = 8 * 1_024 * 1_024
    let fileURL: URL
    private let atomicReplace: (URL, URL) throws -> Void

    init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudeIsolationPoC", isDirectory: true)
        .appendingPathComponent("text-skills.json"),
         atomicReplace: @escaping (URL, URL) throws -> Void = { temporary, destination in
             guard Darwin.rename(temporary.path, destination.path) == 0 else { throw TextSkillFailure.saveFailed }
         }) {
        self.fileURL = fileURL
        self.atomicReplace = atomicReplace
    }

    func load() throws -> TextSkillsSnapshot {
        guard fileURL.isFileURL else { throw TextSkillFailure.readFailed }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return .empty
        } catch { throw TextSkillFailure.readFailed }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw TextSkillFailure.readFailed }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= Self.maximumBytes else {
            throw TextSkillFailure.fileTooLarge
        }
        let data = try textSkillsReadFile(fileURL, maximumBytes: Self.maximumBytes, failure: .readFailed)
        guard data.count <= Self.maximumBytes else { throw TextSkillFailure.fileTooLarge }
        do { return try JSONDecoder().decode(TextSkillsSnapshot.self, from: data) }
        catch let error as TextSkillFailure { throw error }
        catch { throw TextSkillFailure.invalidFormat }
    }

    func save(_ snapshot: TextSkillsSnapshot) throws {
        guard fileURL.isFileURL else { throw TextSkillFailure.saveFailed }
        try snapshot.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(snapshot) }
        catch { throw TextSkillFailure.invalidFormat }
        guard data.count <= Self.maximumBytes else { throw TextSkillFailure.fileTooLarge }
        // Preserve corrupt or newer persisted instructions, including when they changed after startup.
        _ = try load()
        let folder = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        } catch { throw TextSkillFailure.saveFailed }
        let temporary = folder.appendingPathComponent(".text-skills-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw TextSkillFailure.saveFailed }
        var descriptorOpen = true
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { throw TextSkillFailure.saveFailed }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw TextSkillFailure.saveFailed }
                    offset += written
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw TextSkillFailure.saveFailed }
            let closed = Darwin.close(descriptor)
            descriptorOpen = false
            guard closed == 0 else { throw TextSkillFailure.saveFailed }
            try atomicReplace(temporary, fileURL)
        } catch {
            let closeFailed = descriptorOpen && Darwin.close(descriptor) != 0
            let removeFailed = Darwin.unlink(temporary.path) != 0 && errno != ENOENT
            if closeFailed || removeFailed { throw TextSkillFailure.cleanupFailed }
            throw TextSkillFailure.saveFailed
        }
    }
}

final class MemoryTextSkillStore: TextSkillPersisting {
    var snapshot: TextSkillsSnapshot
    var loadFailure: TextSkillFailure?
    var saveFailure: TextSkillFailure?
    private(set) var saveCount = 0

    init(_ snapshot: TextSkillsSnapshot = .empty) { self.snapshot = snapshot }

    func load() throws -> TextSkillsSnapshot {
        if let loadFailure { throw loadFailure }
        try snapshot.validate()
        return snapshot
    }

    func save(_ snapshot: TextSkillsSnapshot) throws {
        try snapshot.validate()
        if let saveFailure { throw saveFailure }
        if let loadFailure { throw loadFailure }
        self.snapshot = snapshot
        saveCount += 1
    }
}

@MainActor
final class SkillsViewModel: ObservableObject {
    @Published private(set) var skills: [TextSkill] = []
    @Published private(set) var error: String?
    @Published private(set) var status: String?
    private let store: any TextSkillPersisting
    private var loadFailure: TextSkillFailure?

    init(store: any TextSkillPersisting = FileTextSkillStore()) {
        self.store = store
        do {
            let snapshot = try store.load()
            try snapshot.validate()
            skills = snapshot.skills
        } catch {
            let failure = error as? TextSkillFailure ?? .readFailed
            loadFailure = failure
            self.error = failure.message
        }
    }

    func importSkill(at url: URL) {
        mutate(status: "已导入文本快照；默认未启用。外部文件不会被修改。") { candidate in
            candidate.append(try TextSkillImporter.importSkill(at: url))
        }
    }

    func setEnabled(_ id: UUID, enabled: Bool) {
        mutate(status: enabled ? "已启用；下次发送时会使用此文本 Skill。" : "已停用；下次发送时不再使用此文本 Skill。") { candidate in
            guard let index = candidate.firstIndex(where: { $0.id == id }) else { throw TextSkillFailure.unknownSkill }
            candidate[index].isEnabled = enabled
        }
    }

    func remove(_ id: UUID) {
        mutate(status: "已移除 App 中的文本副本；外部 Skill 保留。") { candidate in
            guard let index = candidate.firstIndex(where: { $0.id == id }) else { throw TextSkillFailure.unknownSkill }
            candidate.remove(at: index)
        }
    }

    func enabledContexts() throws -> [TextSkillContext] {
        if let loadFailure { throw loadFailure }
        do { _ = try store.load() }
        catch {
            let failure = error as? TextSkillFailure ?? .readFailed
            self.error = failure.message
            throw failure
        }
        try TextSkillsSnapshot(skills: skills).validate()
        return skills.filter(\.isEnabled).map { TextSkillContext(name: $0.name, content: $0.content) }
    }

    private func mutate(status success: String, operation: (inout [TextSkill]) throws -> Void) {
        status = nil
        do {
            if let loadFailure { throw loadFailure }
            var candidate = skills
            try operation(&candidate)
            let snapshot = TextSkillsSnapshot(skills: candidate)
            try snapshot.validate()
            try store.save(snapshot)
            skills = candidate
            error = nil
            status = success
        } catch { self.error = (error as? TextSkillFailure ?? .saveFailed).message }
    }
}

enum TextSkillImporter {
    static let maximumImportBytes = 65_536

    static func importSkill(at selected: URL) throws -> TextSkill {
        guard selected.isFileURL else { throw TextSkillFailure.invalidSelection }
        let selectedAttributes: [FileAttributeKey: Any]
        do { selectedAttributes = try FileManager.default.attributesOfItem(atPath: selected.path) }
        catch { throw TextSkillFailure.unreadableImport }
        let selectedIsFolder = selectedAttributes[.type] as? FileAttributeType == .typeDirectory
        let source = selectedIsFolder ? selected.appendingPathComponent("SKILL.md") : selected
        guard source.lastPathComponent == "SKILL.md" else { throw TextSkillFailure.invalidSelection }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: source.path) }
        catch { throw TextSkillFailure.unreadableImport }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw TextSkillFailure.unreadableImport }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= maximumImportBytes else {
            throw TextSkillFailure.importTooLarge
        }
        let data = try textSkillsReadFile(source, maximumBytes: maximumImportBytes, failure: .unreadableImport)
        guard data.count <= maximumImportBytes else { throw TextSkillFailure.importTooLarge }
        guard var markdown = String(data: data, encoding: .utf8) else { throw TextSkillFailure.nonUTF8 }
        if markdown.hasPrefix("\u{FEFF}") { markdown.removeFirst() }
        let parsed = try parse(markdown, fallbackName: source.deletingLastPathComponent().lastPathComponent)
        try TextSkillsSnapshot(skills: [parsed]).validate()
        return parsed
    }

    static func parse(_ markdown: String, fallbackName: String) throws -> TextSkill {
        let lines = markdown.components(separatedBy: "\n")
        var name = fallbackName
        var summary = ""
        var content = markdown
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else {
                throw TextSkillFailure.invalidFrontmatter
            }
            var found = Set<String>()
            var index = 1
            while index < end {
                let line = lines[index].trimmingCharacters(in: .newlines)
                guard line.first != " " && line.first != "\t", let colon = line.firstIndex(of: ":") else {
                    index += 1
                    continue
                }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                guard key == "name" || key == "description" else { index += 1; continue }
                guard found.insert(key).inserted else { throw TextSkillFailure.invalidFrontmatter }
                let token = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                var next = index + 1
                while next < end && (lines[next].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || lines[next].first == " " || lines[next].first == "\t") {
                    next += 1
                }
                let value = try metadataValue(token, continuation: Array(lines[(index + 1)..<next]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if key == "name" { name = value } else { summary = value }
                index = next
            }
            content = lines.dropFirst(end + 1).joined(separator: "\n")
        }
        return TextSkill(name: name, summary: summary, content: content)
    }

    private static func metadataValue(_ token: String, continuation: [String]) throws -> String {
        let scalar = stripComment(token)
        if scalar.hasPrefix("|") || scalar.hasPrefix(">") {
            guard scalar.dropFirst().allSatisfy({ $0 == "+" || $0 == "-" || $0.isNumber }),
                  !scalar.contains("0"), scalar.filter({ $0 == "+" || $0 == "-" }).count <= 1,
                  scalar.filter(\.isNumber).count <= 1 else { throw TextSkillFailure.invalidFrontmatter }
            let body = dedented(continuation)
            if scalar.first == "|" { return body.joined(separator: "\n") }
            var folded = ""
            for (index, line) in body.enumerated() {
                if index > 0 { folded += body[index - 1].isEmpty || line.isEmpty ? "\n" : " " }
                folded += line
            }
            return folded
        }
        if scalar.first == "'" {
            guard scalar.last == "'", scalar.count >= 2 else { throw TextSkillFailure.invalidFrontmatter }
            let inner = String(scalar.dropFirst().dropLast())
            var value = ""
            var index = inner.startIndex
            while index < inner.endIndex {
                let character = inner[index]
                if character == "'" {
                    let next = inner.index(after: index)
                    guard next < inner.endIndex, inner[next] == "'" else { throw TextSkillFailure.invalidFrontmatter }
                    value.append("'")
                    index = inner.index(after: next)
                } else { value.append(character); index = inner.index(after: index) }
            }
            guard continuation.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw TextSkillFailure.invalidFrontmatter
            }
            return value
        }
        if scalar.first == "\"" {
            guard let value = try? JSONDecoder().decode(String.self, from: Data(scalar.utf8)),
                  continuation.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw TextSkillFailure.invalidFrontmatter
            }
            return value
        }
        guard !["[", "{", "&", "*", "!"].contains(scalar.first.map(String.init) ?? "") else {
            throw TextSkillFailure.invalidFrontmatter
        }
        return ([scalar] + dedented(continuation)).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func dedented(_ lines: [String]) -> [String] {
        let nonempty = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let indent = nonempty.map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }.min() ?? 0
        return lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : String($0.dropFirst(indent)).trimmingCharacters(in: .newlines) }
    }

    private static func stripComment(_ text: String) -> String {
        var quote: Character?
        var escaped = false
        var previous: Character?
        for index in text.indices {
            let character = text[index]
            if escaped { escaped = false; previous = character; continue }
            if quote == "\"" && character == "\\" { escaped = true; previous = character; continue }
            if character == quote { quote = nil }
            else if quote == nil && (character == "'" || character == "\"") { quote = character }
            else if quote == nil && character == "#" && (previous?.isWhitespace ?? true) {
                return String(text[..<index]).trimmingCharacters(in: .whitespaces)
            }
            previous = character
        }
        return text
    }
}

private func textSkillsReadFile(_ url: URL, maximumBytes: Int, failure: TextSkillFailure) throws -> Data {
    do {
        let handle = try FileHandle(forReadingFrom: url)
        let data: Data
        do { data = try handle.read(upToCount: maximumBytes + 1) ?? Data() }
        catch {
            do { try handle.close() }
            catch { throw failure }
            throw failure
        }
        try handle.close()
        return data
    } catch { throw failure }
}

private struct TextSkillsCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func textSkillsCheckFields(_ decoder: any Decoder, allowed: [String]) throws {
    let fields = try decoder.container(keyedBy: TextSkillsCodingKey.self)
    guard Set(fields.allKeys.map(\.stringValue)).isSubset(of: Set(allowed)) else {
        throw TextSkillFailure.invalidFormat
    }
}
