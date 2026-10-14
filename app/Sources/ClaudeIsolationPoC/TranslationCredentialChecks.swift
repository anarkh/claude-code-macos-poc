import Foundation

private final class FixtureTranslationCredentials: AppCredentialStoring {
    var key: String?
    var loads = 0, saves = 0, deletes = 0
    var loadFailure: (any Error)?, saveFailure: (any Error)?, deleteFailure: (any Error)?
    func load() throws -> String? {
        loads += 1
        if let loadFailure { throw loadFailure }
        return key
    }
    func save(_ key: String) throws {
        saves += 1
        if let saveFailure { throw saveFailure }
        self.key = key
    }
    func delete() throws {
        deletes += 1
        if let deleteFailure { throw deleteFailure }
        key = nil
    }
}

@MainActor
func translationCredentialChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("translation_credentials_" + name, passed)) }
    let suite = "com.claude-isolation-poc.translation-credential-tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return [("translation_credentials_suite_available", false)] }
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TranslationConfigurationStore(defaults: defaults)
    let credentials = FixtureTranslationCredentials()
    let model = TranslationViewModel(provider: UnavailableTranslationProvider(), configurationStore: store, credentials: credentials)
    let fixtureKey = "translation-ui-credentials-fake-key"
    check("startup_does_not_read_or_write_credentials", credentials.loads == 0 && credentials.saves == 0 && credentials.deletes == 0 && model.apiKey.isEmpty)
    model.saveKey()
    check("empty_save_is_rejected_without_storage", credentials.saves == 0 && model.credentialStatus == "请先填写 API Key。")
    model.apiKey = " \n "
    model.saveKey()
    check("whitespace_save_is_rejected_without_storage", credentials.saves == 0 && model.credentialStatus == "请先填写 API Key。")
    model.apiKey = fixtureKey
    check("editing_key_changes_memory_only", credentials.saves == 0 && credentials.key == nil && model.credentialStatus == "凭据仅在本次运行内存中。")
    model.saveKey()
    check("explicit_save_uses_injected_store", credentials.saves == 1 && credentials.key == fixtureKey && model.credentialStatus == "已保存到本机。")
    model.saveConfiguration()
    check("public_configuration_save_does_not_write_credentials", credentials.saves == 1 && store.load() == .configured(.init(endpoint: model.endpoint, model: model.modelName)))
    check("public_configuration_contains_no_key", !(String(data: defaults.data(forKey: TranslationConfigurationStore.storageKey) ?? Data(), encoding: .utf8) ?? "").contains(fixtureKey))
    let reopened = TranslationViewModel(provider: UnavailableTranslationProvider(), configurationStore: store, credentials: credentials)
    check("restart_loads_public_profile_without_credentials", reopened.apiKey.isEmpty && reopened.endpoint == model.endpoint && reopened.modelName == model.modelName && credentials.loads == 0)
    reopened.loadKey()
    check("explicit_load_updates_memory_and_status", credentials.loads == 1 && reopened.apiKey == fixtureKey && reopened.credentialStatus == "已读取已保存的 API Key。")
    credentials.key = nil
    reopened.loadKey()
    check("missing_key_has_explicit_message_and_preserves_memory", reopened.apiKey == fixtureKey && reopened.credentialStatus == "本 App 尚未保存翻译模型 API Key。")
    credentials.key = fixtureKey
    reopened.deleteKey()
    check("successful_delete_clears_saved_and_memory_key", credentials.deletes == 1 && credentials.key == nil && reopened.apiKey.isEmpty)
    reopened.apiKey = fixtureKey
    let rawMarker = "fixture-raw-error-with-private-details"
    let rawError = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: rawMarker + fixtureKey])
    credentials.saveFailure = rawError
    reopened.saveKey()
    check("save_failure_preserves_memory_and_saved_state", reopened.apiKey == fixtureKey && credentials.key == nil)
    check("save_failure_hides_raw_error_and_key", reopened.credentialStatus != nil && !(reopened.credentialStatus ?? "").contains(rawMarker) && !(reopened.credentialStatus ?? "").contains(fixtureKey))
    credentials.key = "previous-ui-credentials-fake-key"
    credentials.loadFailure = rawError
    reopened.loadKey()
    check("load_failure_preserves_memory", reopened.apiKey == fixtureKey)
    check("load_failure_hides_raw_error_and_key", reopened.credentialStatus != nil && !(reopened.credentialStatus ?? "").contains(rawMarker) && !(reopened.credentialStatus ?? "").contains(fixtureKey))
    credentials.deleteFailure = rawError
    reopened.deleteKey()
    check("delete_failure_preserves_saved_and_memory_key", reopened.apiKey == fixtureKey && credentials.key == "previous-ui-credentials-fake-key")
    check("delete_failure_hides_raw_error_and_key", reopened.credentialStatus != nil && !(reopened.credentialStatus ?? "").contains(rawMarker) && !(reopened.credentialStatus ?? "").contains(fixtureKey))
    credentials.loadFailure = LocalCredentialFailure.readFailed
    reopened.loadKey()
    check("known_failure_has_actionable_message", reopened.credentialStatus == LocalCredentialFailure.readFailed.message)
    credentials.saveFailure = nil
    reopened.saveKey()
    check("success_after_failure_updates_status", credentials.key == fixtureKey && reopened.credentialStatus == "已保存到本机。")
    return results
}
