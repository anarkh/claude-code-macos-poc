import Foundation

func executionConfigurationChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("execution_config_" + name, passed)) }
    let suiteName = "com.claude-isolation-poc.execution-config-tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        return [("execution_config_test_suite_available", false)]
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = ExecutionConfigurationStore(defaults: defaults)
    let profile = ExecutionModelConfiguration(baseURL: "https://example.invalid/anthropic", model: "fixture-execution-model")
    check("initial_missing", store.load() == .missing)
    do {
        let data = try JSONEncoder().encode(profile)
        check("codable_roundtrip", try JSONDecoder().decode(ExecutionModelConfiguration.self, from: data) == profile)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        check("serialized_fields_are_non_sensitive", object.map { Set($0.keys) == Set(["schemaVersion", "baseURL", "model", "credentialReference", "provider", "subscriptionModel"]) } ?? false)
        check("only_execution_local_file_reference", object?["credentialReference"] as? String == "execution-local-file")
        try store.save(profile)
        check("persist_readback", store.load() == .configured(profile))
        let reopened = ExecutionConfigurationStore(defaults: defaults)
        check("new_store_reads_saved_profile", reopened.load() == .configured(profile))
        defaults.set("translation-fixture-model", forKey: "translation.model")
        check("translation_setting_does_not_change_execution", store.load() == .configured(profile))
        try store.remove()
        check("remove_readback_missing", store.load() == .missing)
        check("execution_remove_preserves_translation", defaults.string(forKey: "translation.model") == "translation-fixture-model")
    } catch { check("roundtrip_and_persistence_setup", false) }

    func invalidPayload(_ name: String, _ fields: [String: Any], _ expected: ExecutionConfigurationError) {
        do {
            defaults.set(try JSONSerialization.data(withJSONObject: fields), forKey: ExecutionConfigurationStore.storageKey)
            check(name, store.load() == .invalid(expected))
        } catch { check(name + "_setup", false) }
    }
    let fields: [String: Any] = ["schemaVersion": 1, "baseURL": profile.baseURL, "model": profile.model, "credentialReference": "execution-local-file"]
    do {
        var legacy = fields; legacy["credentialReference"] = "execution-keychain"
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: ExecutionConfigurationStore.storageKey)
        check("legacy_keychain_marker_reads_as_local_file_without_keychain", store.load() == .configured(profile))
        try store.save(profile)
        let stored = try JSONSerialization.jsonObject(with: defaults.data(forKey: ExecutionConfigurationStore.storageKey) ?? Data()) as? [String: Any]
        check("legacy_profile_save_encodes_local_file_marker", stored?["credentialReference"] as? String == "execution-local-file")
    } catch { check("legacy_marker_setup", false) }
    var badVersion = fields; badVersion["schemaVersion"] = 2
    invalidPayload("unsupported_version", badVersion, .unsupportedVersion)
    var absentModel = fields; absentModel.removeValue(forKey: "model")
    invalidPayload("missing_required_field", absentModel, .invalidFormat)
    var secret = fields; secret["apiKey"] = "fixture-only-key-not-a-credential"
    invalidPayload("secret_field_rejected", secret, .invalidFormat)
    var foreignReference = fields; foreignReference["credentialReference"] = "translation-keychain"
    invalidPayload("foreign_credential_reference_rejected", foreignReference, .invalidFormat)
    for (name, endpoint) in [
        ("http", "http://example.invalid/anthropic"),
        ("userinfo", "https://user:password@example.invalid/anthropic"),
        ("query", "https://example.invalid/anthropic?key=fixture"),
        ("fragment", "https://example.invalid/anthropic#fixture"),
        ("no_host", "https:///anthropic"),
        ("space", " https://example.invalid/anthropic"),
        ("control", "https://example.invalid/anthropic\n")
    ] {
        var payload = fields; payload["baseURL"] = endpoint
        invalidPayload("invalid_url_" + name, payload, .invalidBaseURL)
    }
    var blankModel = fields; blankModel["model"] = "  "
    invalidPayload("blank_model", blankModel, .invalidModel)
    var longModel = fields; longModel["model"] = String(repeating: "m", count: 257)
    invalidPayload("model_size_limit", longModel, .tooLarge)
    defaults.set(Data(repeating: 32, count: ExecutionConfigurationStore.maximumBytes + 1), forKey: ExecutionConfigurationStore.storageKey)
    check("stored_size_limit", store.load() == .invalid(.tooLarge))
    defaults.set("not-profile-data", forKey: ExecutionConfigurationStore.storageKey)
    check("wrong_storage_type", store.load() == .invalid(.invalidFormat))
    defaults.set(Data("not-json".utf8), forKey: ExecutionConfigurationStore.storageKey)
    check("malformed_json", store.load() == .invalid(.invalidFormat))
    do {
        try store.save(profile)
        do {
            try store.save(.init(baseURL: "http://example.invalid", model: "bad"))
            check("invalid_save_rejected", false)
        } catch let error as ExecutionConfigurationError {
            check("invalid_save_rejected", error == .invalidBaseURL)
        } catch { check("invalid_save_rejected", false) }
        check("invalid_save_preserves_previous_profile", store.load() == .configured(profile))
    } catch { check("save_rejection_setup", false) }
    return results
}
