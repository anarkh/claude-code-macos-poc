import Foundation

enum ExecutionProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case deepseekAPI = "deepseek-api"
    case claudeSubscription = "claude-subscription"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .deepseekAPI: "DeepSeek API"
        case .claudeSubscription: "Claude 订阅"
        }
    }
}

enum ExecutionCredentialReference: String, Codable, Equatable, Sendable {
    case executionLocalFile = "execution-local-file"

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        // Older public profiles stay readable; this marker never routes a Keychain read.
        guard value == Self.executionLocalFile.rawValue || value == "execution-keychain" else {
            throw ExecutionConfigurationError.invalidFormat
        }
        self = .executionLocalFile
    }
}

enum ExecutionConfigurationError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidBaseURL
    case invalidModel
    case invalidFormat
    case tooLarge
    case persistenceFailed

    var message: String {
        switch self {
        case .unsupportedVersion: "Claude Code 配置版本不受支持，请重新保存配置。"
        case .invalidBaseURL: "Claude Code 服务地址需要 HTTPS，且不能包含用户名、密码、查询参数或片段。"
        case .invalidModel: "请填写有效的 Claude Code 模型名称。"
        case .invalidFormat: "Claude Code 配置格式无效，请重新保存配置。"
        case .tooLarge: "Claude Code 配置过大，请缩短服务地址和模型名称。"
        case .persistenceFailed: "Claude Code 配置未能保存，请重试。"
        }
    }
}

struct ExecutionModelConfiguration: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let baseURL: String
    let model: String
    let credentialReference: ExecutionCredentialReference
    let provider: ExecutionProvider
    let subscriptionModel: String

    init(schemaVersion: Int = 1, baseURL: String, model: String,
         credentialReference: ExecutionCredentialReference = .executionLocalFile,
         provider: ExecutionProvider = .deepseekAPI, subscriptionModel: String = "sonnet") {
        self.schemaVersion = schemaVersion
        self.baseURL = baseURL
        self.model = model
        self.credentialReference = credentialReference
        self.provider = provider
        self.subscriptionModel = subscriptionModel
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, baseURL, model, credentialReference, provider, subscriptionModel
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: ExecutionConfigurationCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard fields.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw ExecutionConfigurationError.invalidFormat
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        model = try values.decode(String.self, forKey: .model)
        credentialReference = try values.decode(ExecutionCredentialReference.self, forKey: .credentialReference)
        provider = try values.decodeIfPresent(ExecutionProvider.self, forKey: .provider) ?? .deepseekAPI
        subscriptionModel = try values.decodeIfPresent(String.self, forKey: .subscriptionModel) ?? "sonnet"
        try validate()
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw ExecutionConfigurationError.unsupportedVersion }
        guard baseURL.utf8.count <= 2_048, model.utf8.count <= 256, subscriptionModel.utf8.count <= 256 else {
            throw ExecutionConfigurationError.tooLarge
        }
        guard baseURL == baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
              baseURL.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let parts = URLComponents(string: baseURL), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.url != nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw ExecutionConfigurationError.invalidBaseURL
        }
        guard (provider == .claudeSubscription || !model.isEmpty), model == model.trimmingCharacters(in: .whitespacesAndNewlines),
              model.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ExecutionConfigurationError.invalidModel
        }
        guard ["sonnet", "opus", "haiku"].contains(subscriptionModel) else {
            throw ExecutionConfigurationError.invalidModel
        }
    }
}

private struct ExecutionConfigurationCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

enum ExecutionConfigurationState: Equatable, Sendable {
    case missing
    case configured(ExecutionModelConfiguration)
    case invalid(ExecutionConfigurationError)
}

struct ExecutionConfigurationStore {
    static let storageKey = "claude-code.execution-model.v1"
    static let maximumBytes = 8_192
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> ExecutionConfigurationState {
        guard let stored = defaults.object(forKey: Self.storageKey) else { return .missing }
        guard let data = stored as? Data else { return .invalid(.invalidFormat) }
        guard data.count <= Self.maximumBytes else { return .invalid(.tooLarge) }
        do {
            return .configured(try JSONDecoder().decode(ExecutionModelConfiguration.self, from: data))
        } catch let error as ExecutionConfigurationError {
            return .invalid(error)
        } catch {
            return .invalid(.invalidFormat)
        }
    }

    func save(_ configuration: ExecutionModelConfiguration) throws {
        try configuration.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(configuration)
        guard data.count <= Self.maximumBytes else { throw ExecutionConfigurationError.tooLarge }
        defaults.set(data, forKey: Self.storageKey)
        guard defaults.data(forKey: Self.storageKey) == data else {
            throw ExecutionConfigurationError.persistenceFailed
        }
    }

    func remove() throws {
        defaults.removeObject(forKey: Self.storageKey)
        guard defaults.object(forKey: Self.storageKey) == nil else {
            throw ExecutionConfigurationError.persistenceFailed
        }
    }
}
