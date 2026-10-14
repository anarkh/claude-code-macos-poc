import Foundation

enum NetworkPolicyFailure: Error, Equatable, Sendable {
    case required
    case invalid
    case persistenceFailed

    var code: String {
        switch self {
        case .required: "NETWORK_POLICY_REQUIRED"
        case .invalid: "NETWORK_POLICY_INVALID"
        case .persistenceFailed: "NETWORK_POLICY_SAVE_FAILED"
        }
    }

    var message: String {
        switch self {
        case .required: "缺少统一代理配置，请在设置的网络页面保存代理地址。"
        case .invalid: "网络配置无效。代理地址应为 http://127.0.0.1:端口，例如 http://127.0.0.1:7897；请重新保存。"
        case .persistenceFailed: "网络配置未能确认保存，请重新保存后再试。"
        }
    }
}

struct AppNetworkPolicy: Codable, Equatable, Sendable {
    let schema: String
    let proxyURL: String
    let dnsPolicy: String

    static let defaultPolicy = AppNetworkPolicy(proxyURL: "http://127.0.0.1:7897")

    init(schema: String = "app-network-policy/v1", proxyURL: String, dnsPolicy: String = "proxy-only") {
        self.schema = schema
        self.proxyURL = proxyURL
        self.dnsPolicy = dnsPolicy
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case schema, proxyURL, dnsPolicy }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: NetworkConfigurationCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard fields.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw NetworkPolicyFailure.invalid
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(String.self, forKey: .schema)
        proxyURL = try values.decode(String.self, forKey: .proxyURL)
        dnsPolicy = try values.decode(String.self, forKey: .dnsPolicy)
        try validate()
    }

    func validate() throws {
        let prefix = "http://127.0.0.1:"
        guard schema == "app-network-policy/v1", dnsPolicy == "proxy-only",
              proxyURL.utf8.count <= 128, proxyURL.hasPrefix(prefix) else {
            throw NetworkPolicyFailure.invalid
        }
        let portText = proxyURL.dropFirst(prefix.count)
        guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(portText), (1...65_535).contains(port),
              proxyURL == prefix + String(port) else {
            throw NetworkPolicyFailure.invalid
        }
    }
}

private struct NetworkConfigurationCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

protocol NetworkPolicyProviding: Sendable {
    func snapshot() throws -> AppNetworkPolicy
}

struct SavedNetworkPolicyProvider: NetworkPolicyProviding {
    func snapshot() throws -> AppNetworkPolicy { try NetworkConfigurationStore().load() }
}

struct FixedNetworkPolicyProvider: NetworkPolicyProviding {
    let policy: AppNetworkPolicy
    init(policy: AppNetworkPolicy = .defaultPolicy) { self.policy = policy }
    func snapshot() throws -> AppNetworkPolicy {
        try policy.validate()
        return policy
    }
}

protocol NetworkConfigurationPersisting {
    func load() throws -> AppNetworkPolicy
    func save(_ policy: AppNetworkPolicy) throws
}

struct NetworkConfigurationStore: NetworkConfigurationPersisting {
    static let storageKey = "claude-code.app-network-policy.v1"
    static let maximumBytes = 1_024
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() throws -> AppNetworkPolicy {
        guard let stored = defaults.object(forKey: Self.storageKey) else { return .defaultPolicy }
        guard let data = stored as? Data, data.count <= Self.maximumBytes else {
            throw NetworkPolicyFailure.invalid
        }
        do { return try JSONDecoder().decode(AppNetworkPolicy.self, from: data) }
        catch { throw NetworkPolicyFailure.invalid }
    }

    func save(_ policy: AppNetworkPolicy) throws {
        try policy.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(policy) }
        catch { throw NetworkPolicyFailure.invalid }
        guard data.count <= Self.maximumBytes else { throw NetworkPolicyFailure.invalid }
        defaults.set(data, forKey: Self.storageKey)
        guard defaults.data(forKey: Self.storageKey) == data else { throw NetworkPolicyFailure.persistenceFailed }
        do {
            guard try load() == policy else { throw NetworkPolicyFailure.persistenceFailed }
        } catch { throw NetworkPolicyFailure.persistenceFailed }
    }
}

final class MemoryNetworkConfigurationStore: NetworkConfigurationPersisting {
    private var policy: AppNetworkPolicy
    init(policy: AppNetworkPolicy = .defaultPolicy) { self.policy = policy }
    func load() throws -> AppNetworkPolicy {
        try policy.validate()
        return policy
    }
    func save(_ policy: AppNetworkPolicy) throws {
        try policy.validate()
        self.policy = policy
    }
}
