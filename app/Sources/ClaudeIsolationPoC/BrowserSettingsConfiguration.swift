import Foundation

enum BrowserSettingsFailure: Error, LocalizedError, Equatable {
    case invalidProxy, persistenceFailed, busy
    var errorDescription: String? {
        switch self {
        case .invalidProxy: "浏览器代理地址应为 http://127.0.0.1:端口，例如 http://127.0.0.1:17897。"
        case .persistenceFailed: "浏览器代理配置未能确认保存，请重新保存。"
        case .busy: "请先停止浏览器，再修改代理或清除资料。"
        }
    }
}

struct BrowserSettingsConfiguration: Codable, Equatable, Sendable {
    var schema = "browser-settings/v1"
    var proxyURL: String
    var resistFingerprinting = false
    static let defaultConfiguration = Self(proxyURL: "http://127.0.0.1:17897")
    func validate() throws {
        let prefix = "http://127.0.0.1:"
        guard schema == "browser-settings/v1", proxyURL.hasPrefix(prefix), proxyURL.utf8.count <= 128 else {
            throw BrowserSettingsFailure.invalidProxy
        }
        let portText = proxyURL.dropFirst(prefix.count)
        guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(portText), (1...65_535).contains(port), proxyURL == prefix + String(port) else {
            throw BrowserSettingsFailure.invalidProxy
        }
    }
}

struct BrowserSettingsStore {
    static let storageKey = "claude-code.browser-settings.v1"
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() throws -> BrowserSettingsConfiguration {
        guard let object = defaults.object(forKey: Self.storageKey) else { return .defaultConfiguration }
        guard let data = object as? Data, data.count <= 1_024 else { throw BrowserSettingsFailure.invalidProxy }
        let configuration: BrowserSettingsConfiguration
        do { configuration = try JSONDecoder().decode(BrowserSettingsConfiguration.self, from: data) }
        catch { throw BrowserSettingsFailure.invalidProxy }
        try configuration.validate()
        return configuration
    }
    func save(_ configuration: BrowserSettingsConfiguration) throws {
        try configuration.validate()
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: Self.storageKey)
        guard defaults.data(forKey: Self.storageKey) == data, try load() == configuration else {
            throw BrowserSettingsFailure.persistenceFailed
        }
    }
}
