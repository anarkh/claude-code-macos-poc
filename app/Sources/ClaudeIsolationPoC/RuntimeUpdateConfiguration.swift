import Foundation

struct RuntimeUpdateConfiguration: Codable, Equatable, Sendable {
    let schema: String
    let channelURL: String

    static let schemaValue = "runtime-update-source/v1"
    static let unconfigured = RuntimeUpdateConfiguration(channelURL: "")

    init(channelURL: String) {
        self.schema = Self.schemaValue
        self.channelURL = channelURL
    }

    private enum CodingKeys: String, CodingKey { case schema, channelURL }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: RuntimeUpdateConfigurationCodingKey.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(["schema", "channelURL"]) else {
            throw RuntimeUpdateFailure.invalidSource
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(String.self, forKey: .schema)
        channelURL = try values.decode(String.self, forKey: .channelURL)
        try validate()
    }

    /// An empty configuration deliberately does not select a remote source.
    var feedURL: URL? {
        guard !channelURL.isEmpty, (try? validate()) != nil else { return nil }
        return URL(string: channelURL)
    }

    func validate() throws {
        guard schema == Self.schemaValue else { throw RuntimeUpdateFailure.invalidSource }
        if channelURL.isEmpty { return }
        guard channelURL.utf8.count <= 2_048,
              channelURL.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !channelURL.contains("\\"),
              let parts = URLComponents(string: channelURL),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              parts.url != nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65_535).contains($0) }) ?? true,
              parts.percentEncodedPath.hasSuffix("/channel.json") else {
            throw RuntimeUpdateFailure.invalidSource
        }
        guard let schemeEnd = channelURL.range(of: "://"),
              let pathStart = channelURL[schemeEnd.upperBound...].firstIndex(of: "/"),
              String(channelURL[pathStart...]) == parts.percentEncodedPath else {
            throw RuntimeUpdateFailure.invalidSource
        }
        for component in parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
            guard !component.isEmpty, let decoded = String(component).removingPercentEncoding,
                  decoded != ".", decoded != "..", !decoded.contains("/"), !decoded.contains("\\"),
                  decoded.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
                throw RuntimeUpdateFailure.invalidSource
            }
        }
    }

    static func validateFeedURL(_ url: URL) throws {
        guard !url.isFileURL, url.baseURL == nil else { throw RuntimeUpdateFailure.invalidSource }
        try RuntimeUpdateConfiguration(channelURL: url.absoluteString).validate()
    }
}

private struct RuntimeUpdateConfigurationCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

protocol RuntimeUpdateConfigurationPersisting {
    func load() throws -> RuntimeUpdateConfiguration
    func save(_ configuration: RuntimeUpdateConfiguration) throws
}

struct RuntimeUpdateConfigurationStore: RuntimeUpdateConfigurationPersisting {
    static let storageKey = "claude-code.runtime-update-source.v1"
    static let maximumBytes = 4_096
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() throws -> RuntimeUpdateConfiguration {
        guard let stored = defaults.object(forKey: Self.storageKey) else { return .unconfigured }
        guard let data = stored as? Data, data.count <= Self.maximumBytes else {
            throw RuntimeUpdateFailure.invalidSource
        }
        do { return try JSONDecoder().decode(RuntimeUpdateConfiguration.self, from: data) }
        catch { throw RuntimeUpdateFailure.invalidSource }
    }

    func save(_ configuration: RuntimeUpdateConfiguration) throws {
        try configuration.validate()
        if configuration.channelURL.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
            guard defaults.object(forKey: Self.storageKey) == nil else {
                throw RuntimeUpdateFailure.persistenceFailed
            }
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data: Data
            do { data = try encoder.encode(configuration) }
            catch { throw RuntimeUpdateFailure.invalidSource }
            guard data.count <= Self.maximumBytes else { throw RuntimeUpdateFailure.invalidSource }
            defaults.set(data, forKey: Self.storageKey)
            guard defaults.data(forKey: Self.storageKey) == data else {
                throw RuntimeUpdateFailure.persistenceFailed
            }
        }
        do {
            guard try load() == configuration else { throw RuntimeUpdateFailure.persistenceFailed }
        } catch { throw RuntimeUpdateFailure.persistenceFailed }
    }
}

final class MemoryRuntimeUpdateConfigurationStore: RuntimeUpdateConfigurationPersisting {
    private var configuration: RuntimeUpdateConfiguration
    init(configuration: RuntimeUpdateConfiguration = .unconfigured) { self.configuration = configuration }
    func load() throws -> RuntimeUpdateConfiguration {
        try configuration.validate()
        return configuration
    }
    func save(_ configuration: RuntimeUpdateConfiguration) throws {
        try configuration.validate()
        self.configuration = configuration
    }
}
