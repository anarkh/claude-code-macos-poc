import Foundation

@MainActor
func networkConfigurationChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("network_config_" + name, passed)) }
    let suiteName = "com.claude-isolation-poc.network-config-tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        return [("network_config_test_suite_available", false)]
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = NetworkConfigurationStore(defaults: defaults)
    let policy = AppNetworkPolicy(proxyURL: "http://127.0.0.1:7898")
    let fields: [String: Any] = ["schema": policy.schema, "proxyURL": policy.proxyURL, "dnsPolicy": policy.dnsPolicy]
    func rejected(_ action: () throws -> Void) -> Bool {
        do { try action(); return false }
        catch let error as NetworkPolicyFailure { return error == .invalid }
        catch { return false }
    }
    do {
        check("missing_uses_loopback_proxy_default", try store.load() == .defaultPolicy)
        let data = try JSONEncoder().encode(policy)
        check("codable_roundtrip", try JSONDecoder().decode(AppNetworkPolicy.self, from: data) == policy)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        check("only_public_network_fields", object.map { Set($0.keys) == Set(["schema", "proxyURL", "dnsPolicy"]) } ?? false)
        defaults.set(Data("execution-public-fixture".utf8), forKey: ExecutionConfigurationStore.storageKey)
        defaults.set(Data("translation-public-fixture".utf8), forKey: TranslationConfigurationStore.storageKey)
        try store.save(policy)
        check("persist_readback", try store.load() == policy)
        check("reopened_store_reads_persisted_policy", try NetworkConfigurationStore(defaults: defaults).load() == policy)
        check("save_preserves_model_settings", defaults.data(forKey: ExecutionConfigurationStore.storageKey) == Data("execution-public-fixture".utf8)
              && defaults.data(forKey: TranslationConfigurationStore.storageKey) == Data("translation-public-fixture".utf8))
        let priorData = defaults.data(forKey: NetworkConfigurationStore.storageKey)
        check("invalid_save_rejected", rejected { try store.save(.init(proxyURL: "http://localhost:7897")) })
        check("invalid_save_preserves_previous_policy", try store.load() == policy && defaults.data(forKey: NetworkConfigurationStore.storageKey) == priorData)
        check("fixed_provider_validates_snapshot", try FixedNetworkPolicyProvider(policy: policy).snapshot() == policy)
        check("fixed_provider_rejects_direct_dns", rejected { _ = try FixedNetworkPolicyProvider(policy: .init(proxyURL: policy.proxyURL, dnsPolicy: "local")).snapshot() })
    } catch { check("roundtrip_persistence_setup", false) }

    for port in [1, 65_535] {
        do { try AppNetworkPolicy(proxyURL: "http://127.0.0.1:\(port)").validate(); check("boundary_port_\(port)", true) }
        catch { check("boundary_port_\(port)", false) }
    }
    for (name, url) in [
        ("localhost", "http://localhost:7897"), ("remote_ip", "http://192.168.1.1:7897"),
        ("remote_hostname", "http://proxy.example.invalid:7897"), ("alternate_loopback", "http://127.0.0.2:7897"),
        ("ipv6", "http://[::1]:7897"), ("https_proxy", "https://127.0.0.1:7897"),
        ("socks_proxy", "socks5://127.0.0.1:7897"), ("uppercase", "HTTP://127.0.0.1:7897"),
        ("credentials", "http://user:password@127.0.0.1:7897"), ("path", "http://127.0.0.1:7897/path"),
        ("trailing_slash", "http://127.0.0.1:7897/"), ("query", "http://127.0.0.1:7897?direct=true"),
        ("fragment", "http://127.0.0.1:7897#proxy"), ("missing_port", "http://127.0.0.1"),
        ("zero_port", "http://127.0.0.1:0"), ("large_port", "http://127.0.0.1:65536"),
        ("negative_port", "http://127.0.0.1:-1"), ("plus_port", "http://127.0.0.1:+7897"),
        ("padded_port", "http://127.0.0.1:07897"), ("unicode_port", "http://127.0.0.1:７８９７"),
        ("leading_space", " http://127.0.0.1:7897"), ("trailing_space", "http://127.0.0.1:7897 "),
        ("control", "http://127.0.0.1:7897\n"), ("too_long", "http://127.0.0.1:" + String(repeating: "1", count: 200)),
        ("empty", ""), ("suffix", "http://127.0.0.1:7897.example.invalid")
    ] { check("invalid_proxy_" + name, rejected { try AppNetworkPolicy(proxyURL: url).validate() }) }

    func invalidPayload(_ name: String, _ payload: [String: Any]) {
        do {
            defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: NetworkConfigurationStore.storageKey)
            check(name, rejected { _ = try store.load() })
        } catch { check(name + "_setup", false) }
    }
    var unknownSchema = fields; unknownSchema["schema"] = "app-network-policy/v2"
    invalidPayload("unknown_schema_rejected_without_default", unknownSchema)
    var weakerDNS = fields; weakerDNS["dnsPolicy"] = "direct"
    invalidPayload("direct_dns_policy_rejected", weakerDNS)
    var missing = fields; missing.removeValue(forKey: "proxyURL")
    invalidPayload("missing_proxy_rejected", missing)
    var unknownField = fields; unknownField["allowDirect"] = true
    invalidPayload("unknown_direct_option_rejected", unknownField)
    var bypass = fields; bypass["NO_PROXY"] = "*"
    invalidPayload("no_proxy_bypass_rejected", bypass)
    var noTLS = fields; noTLS["rejectUnauthorized"] = false
    invalidPayload("tls_weakening_option_rejected", noTLS)
    var wrongType = fields; wrongType["proxyURL"] = 7897
    invalidPayload("wrong_field_type_rejected", wrongType)
    defaults.set("not-network-policy-data", forKey: NetworkConfigurationStore.storageKey)
    check("wrong_storage_type_rejected", rejected { _ = try store.load() })
    defaults.set(Data("not-json".utf8), forKey: NetworkConfigurationStore.storageKey)
    check("malformed_json_rejected", rejected { _ = try store.load() })
    defaults.set(Data("[]".utf8), forKey: NetworkConfigurationStore.storageKey)
    check("array_json_rejected", rejected { _ = try store.load() })
    defaults.set(Data(repeating: 32, count: NetworkConfigurationStore.maximumBytes + 1), forKey: NetworkConfigurationStore.storageKey)
    check("oversized_policy_rejected_without_default", rejected { _ = try store.load() })

    do {
        try store.save(policy)
        let model = NetworkSettingsViewModel(store: store)
        check("view_model_loads_saved_proxy", model.proxyURL == policy.proxyURL && model.error == nil)
        let oldStatus = model.status
        model.proxyURL = "http://localhost:7897"; model.save()
        check("invalid_save_keeps_user_draft_and_status", model.proxyURL == "http://localhost:7897" && model.status == oldStatus && model.error == NetworkPolicyFailure.invalid.message)
        check("invalid_view_model_save_keeps_persisted_proxy", try store.load() == policy)
        model.proxyURL = "http://127.0.0.1:8901"; model.save()
        check("view_model_valid_save_readback", try store.load().proxyURL == "http://127.0.0.1:8901" && model.error == nil)
        model.restoreDefault()
        check("view_model_default_restores_and_persists", try store.load() == .defaultPolicy && model.proxyURL == AppNetworkPolicy.defaultPolicy.proxyURL && model.error == nil)
    } catch { check("view_model_persistence_setup", false) }

    let faultStore = NetworkCheckStore(policy: policy)
    let failingModel = NetworkSettingsViewModel(store: faultStore)
    let priorStatus = failingModel.status
    faultStore.failSave = true
    failingModel.proxyURL = "http://127.0.0.1:8902"; failingModel.save()
    check("persistence_failure_is_actionable", failingModel.error == NetworkPolicyFailure.persistenceFailed.message)
    check("persistence_failure_keeps_old_policy_and_status", faultStore.policy == policy && failingModel.status == priorStatus && failingModel.proxyURL == "http://127.0.0.1:8902")
    failingModel.restoreDefault()
    check("restore_failure_keeps_old_policy_and_draft", faultStore.policy == policy && failingModel.proxyURL == "http://127.0.0.1:8902")
    faultStore.failLoad = true
    let invalidModel = NetworkSettingsViewModel(store: faultStore)
    check("load_failure_does_not_show_default_as_saved", invalidModel.proxyURL.isEmpty && invalidModel.error == NetworkPolicyFailure.invalid.message)
    let persistedBeforeFixture = defaults.data(forKey: NetworkConfigurationStore.storageKey)
    let fixtureStore = MemoryNetworkConfigurationStore()
    let fixtureModel = NetworkSettingsViewModel(store: fixtureStore)
    fixtureModel.proxyURL = policy.proxyURL; fixtureModel.save()
    check("fixture_store_is_independent_from_user_defaults", defaults.data(forKey: NetworkConfigurationStore.storageKey) == persistedBeforeFixture)
    do { check("fixture_memory_policy_saved", try fixtureStore.load() == policy) }
    catch { check("fixture_memory_policy_saved", false) }
    return results
}

private final class NetworkCheckStore: NetworkConfigurationPersisting {
    var policy: AppNetworkPolicy
    var failSave = false
    var failLoad = false
    init(policy: AppNetworkPolicy) { self.policy = policy }
    func load() throws -> AppNetworkPolicy {
        if failLoad { throw NetworkPolicyFailure.invalid }
        return policy
    }
    func save(_ policy: AppNetworkPolicy) throws {
        if failSave { throw NetworkPolicyFailure.persistenceFailed }
        self.policy = policy
    }
}
