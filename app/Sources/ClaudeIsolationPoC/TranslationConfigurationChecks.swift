import Foundation

func translationConfigurationChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("translation_config_" + name, passed)) }
    let suiteName = "com.claude-isolation-poc.translation-config-tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        return [("translation_config_test_suite_available", false)]
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = TranslationConfigurationStore(defaults: defaults)
    let executionStore = ExecutionConfigurationStore(defaults: defaults)
    let profile = TranslationPublicConfiguration(endpoint: "https://example.invalid/chat/completions", model: "fixture-translation-model")
    let executionProfile = ExecutionModelConfiguration(baseURL: "https://example.invalid/anthropic", model: "fixture-execution-model")
    check("initial_missing", store.load() == .missing)
    check("storage_scope_differs_from_execution", TranslationConfigurationStore.storageKey != ExecutionConfigurationStore.storageKey)
    do {
        let data = try JSONEncoder().encode(profile)
        check("codable_roundtrip", try JSONDecoder().decode(TranslationPublicConfiguration.self, from: data) == profile)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        check("serialized_fields_are_public_only", object.map { Set($0.keys) == Set(["schemaVersion", "endpoint", "model"]) } ?? false)
        try executionStore.save(executionProfile)
        try store.save(profile)
        check("persist_readback", store.load() == .configured(profile))
        check("new_store_reads_saved_profile", TranslationConfigurationStore(defaults: defaults).load() == .configured(profile))
        check("translation_save_preserves_execution", executionStore.load() == .configured(executionProfile))
        try executionStore.save(.init(baseURL: "https://other.example.invalid/anthropic", model: "other-execution-model"))
        check("execution_save_preserves_translation", store.load() == .configured(profile))
        let savedExecution = executionStore.load()
        try store.remove()
        check("remove_readback_missing", store.load() == .missing)
        check("translation_remove_preserves_execution", executionStore.load() == savedExecution)
    } catch { check("roundtrip_and_persistence_setup", false) }

    func invalidPayload(_ name: String, _ fields: [String: Any], _ expected: TranslationConfigurationError) {
        do {
            defaults.set(try JSONSerialization.data(withJSONObject: fields), forKey: TranslationConfigurationStore.storageKey)
            check(name, store.load() == .invalid(expected))
        } catch { check(name + "_setup", false) }
    }
    let fields: [String: Any] = ["schemaVersion": 1, "endpoint": profile.endpoint, "model": profile.model]
    var badVersion = fields; badVersion["schemaVersion"] = 2
    invalidPayload("unsupported_version", badVersion, .unsupportedVersion)
    var absentModel = fields; absentModel.removeValue(forKey: "model")
    invalidPayload("missing_required_field", absentModel, .invalidFormat)
    var secret = fields; secret["apiKey"] = "fixture-only-key-not-a-credential"
    invalidPayload("secret_field_rejected", secret, .invalidFormat)
    var executionReference = fields; executionReference["credentialReference"] = "execution-keychain"
    invalidPayload("execution_reference_rejected", executionReference, .invalidFormat)
    var wrongType = fields; wrongType["model"] = 12
    invalidPayload("wrong_model_type", wrongType, .invalidFormat)
    for (name, endpoint) in [
        ("http", "http://example.invalid/chat/completions"),
        ("userinfo", "https://user:password@example.invalid/chat/completions"),
        ("query", "https://example.invalid/chat/completions?key=fixture"),
        ("fragment", "https://example.invalid/chat/completions#fixture"),
        ("no_host", "https:///chat/completions"),
        ("space", " https://example.invalid/chat/completions"),
        ("control", "https://example.invalid/chat/completions\n")
    ] {
        var payload = fields; payload["endpoint"] = endpoint
        invalidPayload("invalid_endpoint_" + name, payload, .invalidEndpoint)
    }
    var blankModel = fields; blankModel["model"] = "  "
    invalidPayload("blank_model", blankModel, .invalidModel)
    var controlModel = fields; controlModel["model"] = "model\nname"
    invalidPayload("control_model", controlModel, .invalidModel)
    var longModel = fields; longModel["model"] = String(repeating: "m", count: 257)
    invalidPayload("model_size_limit", longModel, .tooLarge)
    var longEndpoint = fields; longEndpoint["endpoint"] = "https://example.invalid/" + String(repeating: "p", count: 2_048)
    invalidPayload("endpoint_size_limit", longEndpoint, .tooLarge)
    defaults.set(Data(repeating: 32, count: TranslationConfigurationStore.maximumBytes + 1), forKey: TranslationConfigurationStore.storageKey)
    check("stored_size_limit", store.load() == .invalid(.tooLarge))
    defaults.set("not-profile-data", forKey: TranslationConfigurationStore.storageKey)
    check("wrong_storage_type", store.load() == .invalid(.invalidFormat))
    defaults.set(Data("not-json".utf8), forKey: TranslationConfigurationStore.storageKey)
    check("malformed_json", store.load() == .invalid(.invalidFormat))
    do {
        try store.save(profile)
        do {
            try store.save(.init(endpoint: "http://example.invalid", model: "bad"))
            check("invalid_save_rejected", false)
        } catch let error as TranslationConfigurationError {
            check("invalid_save_rejected", error == .invalidEndpoint)
        } catch { check("invalid_save_rejected", false) }
        check("invalid_save_preserves_previous_profile", store.load() == .configured(profile))
    } catch { check("save_rejection_setup", false) }
    return results
}
