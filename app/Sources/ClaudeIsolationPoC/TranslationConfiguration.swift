import Foundation

enum TranslationConfigurationError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidEndpoint
    case invalidModel
    case invalidFormat
    case tooLarge
    case persistenceFailed

    var message: String {
        switch self {
        case .unsupportedVersion: "翻译模型配置版本不受支持，请重新保存配置。"
        case .invalidEndpoint: "翻译服务地址需要 HTTPS，且不能包含用户名、密码、查询参数或片段。"
        case .invalidModel: "请填写有效的翻译模型名称。"
        case .invalidFormat: "翻译模型配置格式无效，请重新保存配置。"
        case .tooLarge: "翻译模型配置过大，请缩短服务地址和模型名称。"
        case .persistenceFailed: "翻译模型配置未能保存，请重试。"
        }
    }
}

// Only public routing settings are persisted. The API key has a separate Keychain scope.
struct TranslationPublicConfiguration: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let endpoint: String
    let model: String

    init(schemaVersion: Int = 1, endpoint: String, model: String) {
        self.schemaVersion = schemaVersion
        self.endpoint = endpoint
        self.model = model
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, endpoint, model
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: TranslationConfigurationCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard fields.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw TranslationConfigurationError.invalidFormat
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        endpoint = try values.decode(String.self, forKey: .endpoint)
        model = try values.decode(String.self, forKey: .model)
        try validate()
    }

    func validate() throws {
        do {
            try ExecutionModelConfiguration(schemaVersion: schemaVersion, baseURL: endpoint, model: model).validate()
        } catch let error as ExecutionConfigurationError {
            switch error {
            case .unsupportedVersion: throw TranslationConfigurationError.unsupportedVersion
            case .invalidBaseURL: throw TranslationConfigurationError.invalidEndpoint
            case .invalidModel: throw TranslationConfigurationError.invalidModel
            case .invalidFormat: throw TranslationConfigurationError.invalidFormat
            case .tooLarge: throw TranslationConfigurationError.tooLarge
            case .persistenceFailed: throw TranslationConfigurationError.persistenceFailed
            }
        }
    }
}

private struct TranslationConfigurationCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

enum TranslationConfigurationState: Equatable, Sendable {
    case missing
    case configured(TranslationPublicConfiguration)
    case invalid(TranslationConfigurationError)
}

struct TranslationConfigurationStore {
    static let storageKey = "claude-code.translation-model.v1"
    static let maximumBytes = 8_192
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> TranslationConfigurationState {
        guard let stored = defaults.object(forKey: Self.storageKey) else { return .missing }
        guard let data = stored as? Data else { return .invalid(.invalidFormat) }
        guard data.count <= Self.maximumBytes else { return .invalid(.tooLarge) }
        do {
            return .configured(try JSONDecoder().decode(TranslationPublicConfiguration.self, from: data))
        } catch let error as TranslationConfigurationError {
            return .invalid(error)
        } catch {
            return .invalid(.invalidFormat)
        }
    }

    func save(_ configuration: TranslationPublicConfiguration) throws {
        try configuration.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(configuration)
        guard data.count <= Self.maximumBytes else { throw TranslationConfigurationError.tooLarge }
        defaults.set(data, forKey: Self.storageKey)
        guard defaults.data(forKey: Self.storageKey) == data else {
            throw TranslationConfigurationError.persistenceFailed
        }
    }

    func remove() throws {
        defaults.removeObject(forKey: Self.storageKey)
        guard defaults.object(forKey: Self.storageKey) == nil else {
            throw TranslationConfigurationError.persistenceFailed
        }
    }
}
