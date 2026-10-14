import Foundation

private final class MemoryConnectionCredentials: AppCredentialStoring {
    var loads = 0
    func load() throws -> String? { loads += 1; return "fixture-only-connection-key" }
    func save(_ key: String) throws {}
    func delete() throws {}
}
private struct MemoryConnectionTester: ExecutionConnectionTesting {
    var delay = false
    var failure: String?
    func test(apiKey: String, model: String) async throws -> ExecutionConnectionReply {
        if delay { try await Task.sleep(nanoseconds: 80_000_000) }
        if let failure { throw ExecutionConnectionFailure(code: failure) }
        return .init(ok: true, code: "PASSED_TEXT_ONLY", model: model, ack: "DEEPSEEK_CLI_OK", no_tools: true, request_count: 1,
                     cli: .init(exit_code: 0, signal: nil), cleanup: .init(temporary_removed: true, proxy_closed: true))
    }
}

@MainActor
func executionConnectionViewModelChecks() async -> [(String, Bool)] {
    let name = "com.claude-isolation-poc.connection-checks.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else { return [("connection_test_suite_available", false)] }
    defer { defaults.removePersistentDomain(forName: name) }
    let store = ExecutionConfigurationStore(defaults: defaults)
    do { try store.save(.init(baseURL: "https://api.deepseek.com/anthropic", model: "deepseek-flash[1m]")) }
    catch { return [("connection_test_profile_setup", false)] }
    let keys = MemoryConnectionCredentials()
    let model = ExecutionViewModel(store: store, credentials: keys, tester: MemoryConnectionTester())
    var result = [("connection_startup_does_not_read_credentials", keys.loads == 0)]
    await model.testConnection()
    result.append(("connection_explicit_test_reads_own_credential", keys.loads == 1))
    result.append(("connection_success_text_displayed", model.testStatus?.contains("DEEPSEEK_CLI_OK") == true && model.error == nil && !model.testBusy))
    let invalid = ExecutionViewModel(store: store, credentials: keys, tester: MemoryConnectionTester())
    invalid.baseURL = "https://example.invalid/anthropic"
    await invalid.testConnection()
    result.append(("connection_foreign_endpoint_rejected_before_key_read", invalid.error != nil && keys.loads == 1))
    let failed = ExecutionViewModel(store: store, credentials: keys, tester: MemoryConnectionTester(failure: "PROVIDER_HTTP_401"))
    await failed.testConnection()
    result.append(("connection_invalid_key_error_is_actionable", failed.error?.contains("API Key") == true && !failed.testBusy))
    let stale = ExecutionViewModel(store: store, credentials: keys, tester: MemoryConnectionTester(delay: true))
    let running = Task { await stale.testConnection() }
    await Task.yield()
    stale.modelName = "different-fixture-model"
    await running.value
    result.append(("connection_changed_configuration_discards_old_success", stale.error?.contains("配置已更改") == true && stale.testStatus?.contains("未通过") == true))
    result.append(("connection_success_never_opens_project_execution", !TranslationViewModel(provider: UnavailableTranslationProvider()).canSendToClaude))
    return result
}
