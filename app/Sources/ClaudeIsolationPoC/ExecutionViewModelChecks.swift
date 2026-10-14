import Foundation

private final class FixtureExecutionCredentials: AppCredentialStoring {
    var key: String?
    var loads = 0, saves = 0, deletes = 0
    var loadFailure: (any Error)?, saveFailure: (any Error)?, deleteFailure: (any Error)?
    func load() throws -> String? { loads += 1; if let loadFailure { throw loadFailure }; return key }
    func save(_ key: String) throws { saves += 1; if let saveFailure { throw saveFailure }; self.key = key }
    func delete() throws { deletes += 1; if let deleteFailure { throw deleteFailure }; key = nil }
}

@MainActor
func executionViewModelChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("execution_view_model_" + name, passed)) }
    let suite = "com.claude-isolation-poc.execution-vm-tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return [("execution_view_model_suite_available", false)] }
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ExecutionConfigurationStore(defaults: defaults)
    let credentials = FixtureExecutionCredentials()
    let model = ExecutionViewModel(store: store, credentials: credentials)
    check("missing_profile_has_no_guessed_model", model.modelName.isEmpty && store.load() == .missing)
    check("startup_does_not_read_credentials", credentials.loads == 0 && credentials.saves == 0 && model.apiKey.isEmpty)
    model.saveConfiguration()
    check("blank_model_cannot_be_saved", model.error != nil && store.load() == .missing)
    model.modelName = "deepseek-flash[1m]"
    model.saveConfiguration()
    check("public_configuration_saved_without_credentials", model.error == nil && credentials.saves == 0 && store.load() == .configured(.init(baseURL: model.baseURL, model: model.modelName)))
    model.reuseTranslationKey("")
    check("missing_translation_key_explicit_error", model.error != nil && model.apiKey.isEmpty)
    model.reuseTranslationKey("execution-ui-fixture-fake-key")
    check("reuse_is_memory_only", model.error == nil && model.apiKey == "execution-ui-fixture-fake-key" && credentials.loads == 0 && credentials.saves == 0)
    let reopened = ExecutionViewModel(store: store, credentials: credentials)
    check("reopen_loads_public_profile_only", reopened.modelName == "deepseek-flash[1m]" && reopened.apiKey.isEmpty && credentials.loads == 0)
    model.saveKey()
    check("explicit_save_uses_scoped_store", credentials.saves == 1 && credentials.key == "execution-ui-fixture-fake-key")
    reopened.loadKey()
    check("explicit_load_uses_scoped_store", credentials.loads == 1 && reopened.apiKey == credentials.key)
    reopened.deleteKey()
    check("delete_clears_scoped_key_and_memory", credentials.deletes == 1 && credentials.key == nil && reopened.apiKey.isEmpty)
    reopened.loadKey()
    check("missing_execution_key_explicit_error", reopened.error != nil && reopened.apiKey.isEmpty)
    let translationCredentials = FixtureExecutionCredentials()
    let translation = TranslationViewModel(provider: UnavailableTranslationProvider(), configurationStore: .init(defaults: defaults), credentials: translationCredentials)
    translation.apiKey = "translation-ui-fixture-fake-key"
    translation.saveKey()
    check("translation_save_uses_separate_credentials", translationCredentials.key == translation.apiKey && credentials.key == nil)
    reopened.apiKey = "independent-execution-ui-fixture-fake-key"
    reopened.saveKey()
    check("execution_save_preserves_translation_credentials", credentials.key == reopened.apiKey && translationCredentials.key == translation.apiKey)
    let rawMarker = "fixture-raw-error-with-private-details"
    let rawError = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: rawMarker + reopened.apiKey])
    credentials.saveFailure = rawError
    reopened.saveKey()
    check("save_failure_preserves_in_memory_key", reopened.apiKey == "independent-execution-ui-fixture-fake-key")
    check("save_failure_hides_raw_error_and_key", reopened.error != nil && !(reopened.error ?? "").contains(rawMarker) && !(reopened.error ?? "").contains(reopened.apiKey) && !reopened.credentialStatus.contains(reopened.apiKey))
    credentials.loadFailure = rawError
    reopened.loadKey()
    check("load_failure_preserves_in_memory_key", reopened.apiKey == "independent-execution-ui-fixture-fake-key")
    check("load_failure_hides_raw_error_and_key", reopened.error != nil && !(reopened.error ?? "").contains(rawMarker) && !(reopened.error ?? "").contains(reopened.apiKey))
    credentials.deleteFailure = rawError
    reopened.deleteKey()
    check("delete_failure_preserves_saved_and_memory_key", reopened.apiKey == "independent-execution-ui-fixture-fake-key" && credentials.key == reopened.apiKey)
    check("delete_failure_hides_raw_error_and_key", reopened.error != nil && !(reopened.error ?? "").contains(rawMarker) && !(reopened.error ?? "").contains(reopened.apiKey))
    credentials.loadFailure = LocalCredentialFailure.readFailed
    reopened.loadKey()
    check("known_credential_failure_has_actionable_message", reopened.error == LocalCredentialFailure.readFailed.message)
    credentials.saveFailure = nil
    reopened.saveKey()
    check("successful_save_clears_error_and_reports_local_storage", reopened.error == nil && reopened.credentialStatus == "已保存到本机。")
    // Execution settings cannot affect the existing submission gate.
    check("configuration_does_not_open_execution", !translation.canSendToClaude)
    return results
}

private actor FixtureCredentialConnectionTester: ExecutionConnectionTesting {
    private(set) var calls = 0
    func test(apiKey: String, model: String) async throws -> ExecutionConnectionReply {
        calls += 1
        return .init(ok: true, code: "PASSED_TEXT_ONLY", model: model, ack: "DEEPSEEK_CLI_OK", no_tools: true, request_count: 1,
                     cli: .init(exit_code: 0, signal: nil), cleanup: .init(temporary_removed: true, proxy_closed: true))
    }
}

@MainActor
func executionCredentialConnectionChecks() async -> [(String, Bool)] {
    let suite = "com.claude-isolation-poc.execution-credential-connection-tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return [("execution_credentials_connection_suite_available", false)] }
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ExecutionConfigurationStore(defaults: defaults)
    do { try store.save(.init(baseURL: "https://api.deepseek.com/anthropic", model: "deepseek-flash[1m]")) }
    catch { return [("execution_credentials_connection_profile_setup", false)] }
    let credentials = FixtureExecutionCredentials()
    let tester = FixtureCredentialConnectionTester()
    let model = ExecutionViewModel(store: store, credentials: credentials, tester: tester)
    credentials.loadFailure = LocalCredentialFailure.readFailed
    await model.testConnection()
    let callsAfterKnownFailure = await tester.calls
    var results = [("execution_credentials_connection_read_failure_is_actionable_before_provider", model.error == LocalCredentialFailure.readFailed.message && model.apiKey.isEmpty && !model.testBusy && model.testStatus == "连接测试未通过。" && callsAfterKnownFailure == 0)]
    let marker = "fixture-private-error-and-fake-key"
    credentials.loadFailure = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: marker])
    await model.testConnection()
    let callsAfterUnknownFailure = await tester.calls
    results.append(("execution_credentials_connection_raw_read_error_stays_private_before_provider", model.error != nil && !(model.error ?? "").contains(marker) && model.apiKey.isEmpty && !model.testBusy && callsAfterUnknownFailure == 0))
    return results
}
