import Darwin
import Foundation

private final class SubscriptionSettingsFixtureCredentials: AppCredentialStoring {
    var secret: String?
    var failure: (any Error)?
    private(set) var loads = 0, saves = 0, deletes = 0
    init(_ secret: String? = nil) { self.secret = secret }
    func load() throws -> String? { loads += 1; if let failure { throw failure }; return secret }
    func save(_ key: String) throws { if let failure { throw failure }; saves += 1; secret = key }
    func delete() throws { if let failure { throw failure }; deletes += 1; secret = nil }
}

/// Uses isolated preferences, fake OAuth tokens and owned temporary files only.
@MainActor
func subscriptionSettingsChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("subscription_settings_" + name, passed)) }
    let suite = "com.claude-isolation-poc.subscription-settings-tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return [("subscription_settings_suite_available", false)] }
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ExecutionConfigurationStore(defaults: defaults)
    let token = "sk-ant-oat01-subscription-settings-fixture-token"
    let key = "subscription-settings-execution-fake-key"
    let keyStore = SubscriptionSettingsFixtureCredentials(key)
    let tokenStore = SubscriptionSettingsFixtureCredentials(token)
    let vm = ExecutionViewModel(store: store, credentials: keyStore, subscriptionCredentials: tokenStore)
    check("default_provider_is_deepseek", vm.provider == .deepseekAPI && vm.subscriptionModel == "sonnet")
    check("startup_defers_both_secrets", vm.apiKey.isEmpty && vm.subscriptionToken.isEmpty && keyStore.loads == 0 && tokenStore.loads == 0)
    vm.restoreSavedKeyForSettings()
    vm.restoreSavedSubscriptionTokenForSettings()
    check("settings_restores_independent_secrets", vm.apiKey == key && vm.subscriptionToken == token && keyStore.loads == 1 && tokenStore.loads == 1)
    check("settings_restore_is_read_only", keyStore.saves == 0 && tokenStore.saves == 0 && keyStore.deletes == 0 && tokenStore.deletes == 0 && store.load() == .missing)
    vm.subscriptionToken = "sk-ant-oat01-unsaved-subscription-draft"
    vm.restoreSavedSubscriptionTokenForSettings()
    check("settings_preserves_unsaved_token_draft", vm.subscriptionToken == "sk-ant-oat01-unsaved-subscription-draft" && tokenStore.loads == 1 && tokenStore.secret == token)
    vm.provider = .claudeSubscription
    vm.subscriptionModel = "opus"
    vm.saveConfiguration()
    check("subscription_configuration_allows_missing_inactive_deepseek_model", vm.error == nil && vm.modelName.isEmpty)
    do {
        let data = try JSONEncoder().encode(ExecutionModelConfiguration(baseURL: vm.baseURL, model: vm.modelName, provider: vm.provider, subscriptionModel: vm.subscriptionModel))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        check("public_configuration_has_source_and_model_only", object?["provider"] as? String == "claude-subscription" && object?["subscriptionModel"] as? String == "opus" && object?["token"] == nil && object?["subscriptionToken"] == nil && object?["apiKey"] == nil && !String(decoding: data, as: UTF8.self).contains(vm.subscriptionToken))
        check("subscription_public_configuration_roundtrips", try JSONDecoder().decode(ExecutionModelConfiguration.self, from: data).provider == .claudeSubscription)
    } catch { check("public_configuration_fixture", false) }
    let reopened = ExecutionViewModel(store: store, credentials: keyStore, subscriptionCredentials: tokenStore)
    check("restart_restores_source_but_defers_secrets", reopened.provider == .claudeSubscription && reopened.subscriptionModel == "opus" && reopened.subscriptionToken.isEmpty && reopened.apiKey.isEmpty && tokenStore.loads == 1)
    vm.modelName = "deepseek-flash[1m]"
    vm.provider = .deepseekAPI
    vm.saveConfiguration()
    check("switch_preserves_both_configs_and_secrets", vm.error == nil && vm.subscriptionModel == "opus" && vm.apiKey == key && vm.subscriptionToken == "sk-ant-oat01-unsaved-subscription-draft" && tokenStore.secret == token)
    vm.modelName = "unsupported-deepseek-model"
    vm.saveConfiguration()
    check("deepseek_save_rejects_unexecutable_model", vm.error == ExecutionConfigurationError.invalidModel.message)
    vm.modelName = "deepseek-flash"
    vm.baseURL = "https://example.invalid/anthropic"
    vm.saveConfiguration()
    check("deepseek_save_rejects_unexecutable_endpoint", vm.error == ExecutionConfigurationError.invalidBaseURL.message)
    vm.baseURL = "https://api.deepseek.com/anthropic"
    vm.provider = .claudeSubscription
    vm.subscriptionModel = "invented-model"
    vm.saveConfiguration()
    check("subscription_save_rejects_unknown_model", vm.error == ExecutionConfigurationError.invalidModel.message)
    vm.subscriptionModel = "haiku"
    vm.saveConfiguration()
    vm.subscriptionToken = "deepseek-key-must-not-be-subscription-token"
    vm.saveSubscriptionToken()
    check("invalid_token_preserves_saved_value", vm.error == LocalCredentialFailure.invalidSubscriptionToken.message && tokenStore.secret == token && tokenStore.saves == 0)
    vm.subscriptionToken = "sk-ant-oat01-replacement-subscription-token"
    vm.saveSubscriptionToken()
    check("save_token_uses_dedicated_store", vm.error == nil && tokenStore.secret == vm.subscriptionToken && tokenStore.saves == 1 && keyStore.secret == key && keyStore.saves == 0)
    vm.deleteSubscriptionToken()
    check("delete_token_preserves_execution_key_and_config", vm.subscriptionToken.isEmpty && tokenStore.secret == nil && tokenStore.deletes == 1 && keyStore.secret == key && vm.provider == .claudeSubscription)
    vm.loadSubscriptionToken()
    check("missing_token_is_actionable", vm.error?.contains("claude setup-token") == true && vm.subscriptionToken.isEmpty)
    tokenStore.failure = LocalCredentialFailure.readFailed
    vm.restoreSavedSubscriptionTokenForSettings()
    check("restore_failure_is_actionable", vm.subscriptionCredentialStatus == LocalCredentialFailure.readFailed.subscriptionMessage && vm.subscriptionToken.isEmpty)
    let privateMarker = "private-error-fixture-" + token
    tokenStore.failure = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: privateMarker])
    vm.loadSubscriptionToken()
    check("unknown_load_failure_does_not_disclose_raw_error", vm.error != nil && !(vm.error ?? "").contains(privateMarker) && !(vm.error ?? "").contains(token))
    vm.restoreSavedSubscriptionTokenForSettings()
    check("unknown_restore_failure_does_not_disclose_raw_error", !vm.subscriptionCredentialStatus.contains(privateMarker) && !vm.subscriptionCredentialStatus.contains(token))
    tokenStore.failure = nil
    tokenStore.secret = token
    vm.restoreSavedSubscriptionTokenForSettings()
    check("later_restore_recovers_token", vm.subscriptionToken == token && vm.subscriptionCredentialStatus == "已自动恢复本机保存的订阅 Token。")
    vm.apiKey = key
    vm.deleteKey()
    check("delete_execution_key_preserves_subscription_token", keyStore.secret == nil && tokenStore.secret == token && vm.subscriptionToken == token)

    do {
        let legacy: [String: Any] = ["schemaVersion": 1, "baseURL": "https://api.deepseek.com/anthropic", "model": "deepseek-flash[1m]", "credentialReference": "execution-local-file"]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: ExecutionConfigurationStore.storageKey)
        check("legacy_profile_defaults_to_deepseek_and_sonnet", store.load() == .configured(.init(baseURL: "https://api.deepseek.com/anthropic", model: "deepseek-flash[1m]")))
        var unknown = legacy; unknown["provider"] = "unknown-provider"
        defaults.set(try JSONSerialization.data(withJSONObject: unknown), forKey: ExecutionConfigurationStore.storageKey)
        check("unknown_provider_rejected", store.load() == .invalid(.invalidFormat))
        var secret = legacy; secret["subscriptionToken"] = token
        defaults.set(try JSONSerialization.data(withJSONObject: secret), forKey: ExecutionConfigurationStore.storageKey)
        check("public_token_field_rejected", store.load() == .invalid(.invalidFormat))
    } catch { check("legacy_configuration_fixture", false) }

    for invalid in ["sk-ant-api03-api-key-not-oauth", "sk-ant-oat01-token with-space", "sk-ant-oat01-token\n", "sk-ant-oat01-token/invalid", "sk-ant-oat01-" + String(repeating: "x", count: 4_085)] {
        do { try LocalCredentialFailure.validateSubscriptionToken(invalid); check("invalid_token_\(results.count)", false) }
        catch let error as LocalCredentialFailure { check("invalid_token_\(results.count)", error == .invalidSubscriptionToken) }
        catch { check("invalid_token_\(results.count)", false) }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("subscription-settings-files-\(UUID().uuidString)", isDirectory: true)
    let directory = root.appendingPathComponent("Credentials", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let fileToken = FileCredentialStore(scope: .subscription, directoryURL: directory)
        let fileKey = FileCredentialStore(scope: .execution, directoryURL: directory)
        let fileTranslation = FileCredentialStore(scope: .translation, directoryURL: directory)
        try fileKey.save(key)
        try fileTranslation.save("subscription-settings-translation-fake-key")
        let keyBytes = try Data(contentsOf: fileKey.fileURL), translationBytes = try Data(contentsOf: fileTranslation.fileURL)
        try fileToken.save(token)
        check("token_uses_dedicated_filename", fileToken.fileURL.lastPathComponent == "subscription-token.json")
        let fields = try JSONSerialization.jsonObject(with: Data(contentsOf: fileToken.fileURL)) as? [String: Any]
        check("token_snapshot_has_exact_fields", fields.map { Set($0.keys) == ["schemaVersion", "token"] } == true && fields?["schemaVersion"] as? Int == 1 && fields?["token"] as? String == token)
        let fileMode = (try FileManager.default.attributesOfItem(atPath: fileToken.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue
        check("token_permissions_are_0600_and_0700", fileMode == 0o600 && directoryMode == 0o700)
        check("new_store_reads_saved_token", try FileCredentialStore(scope: .subscription, directoryURL: directory).load() == token)
        let tokenBytes = try Data(contentsOf: fileToken.fileURL)
        let failing = FileCredentialStore(scope: .subscription, directoryURL: directory, atomicReplace: { _, _ in throw LocalCredentialFailure.saveFailed })
        do { try failing.save("sk-ant-oat01-replacement-fake-token"); check("atomic_failure_explicit", false) }
        catch let error as LocalCredentialFailure { check("atomic_failure_explicit", error == .saveFailed) }
        check("atomic_failure_preserves_token_bytes", try Data(contentsOf: fileToken.fileURL) == tokenBytes)
        check("atomic_failure_cleans_temporary_file", try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".credential-") })
        let longToken = "sk-ant-oat01-" + String(repeating: "x", count: 4_083)
        try fileToken.save(longToken)
        check("max_length_token_roundtrips", try FileCredentialStore(scope: .subscription, directoryURL: directory).load() == longToken && longToken.utf8.count == 4_096)
        try fileToken.delete()
        check("token_delete_preserves_other_scopes", try FileCredentialStore(scope: .subscription, directoryURL: directory).load() == nil && Data(contentsOf: fileKey.fileURL) == keyBytes && Data(contentsOf: fileTranslation.fileURL) == translationBytes)
        try Data("{\"schemaVersion\":1,\"apiKey\":\"subscription-settings-wrong-scope-key\"}".utf8).write(to: fileToken.fileURL)
        do { _ = try FileCredentialStore(scope: .subscription, directoryURL: directory).load(); check("api_key_snapshot_rejected_in_token_scope", false) }
        catch let error as LocalCredentialFailure { check("api_key_snapshot_rejected_in_token_scope", error == .invalidFormat) }
        try FileCredentialStore(scope: .subscription, directoryURL: directory).delete()
        try FileManager.default.createSymbolicLink(at: fileToken.fileURL, withDestinationURL: fileKey.fileURL)
        do { _ = try FileCredentialStore(scope: .subscription, directoryURL: directory).load(); check("token_symlink_rejected", false) }
        catch let error as LocalCredentialFailure { check("token_symlink_rejected", error == .readFailed) }
        check("symlink_probe_preserves_execution_key", try Data(contentsOf: fileKey.fileURL) == keyBytes)
    } catch { check("temporary_file_fixture", false) }
    do { try FileManager.default.removeItem(at: root); check("temporary_files_removed", !FileManager.default.fileExists(atPath: root.path)) }
    catch { check("temporary_files_removed", false) }
    return results
}

private actor SubscriptionConnectionSettingsFixture: ExecutionConnectionTesting {
    let delay: Bool
    let failure: String?
    private(set) var deepseekCalls = 0, subscriptionCalls = 0
    private(set) var seenToken: String?, seenModel: String?
    init(delay: Bool = false, failure: String? = nil) { self.delay = delay; self.failure = failure }
    func test(apiKey: String, model: String) async throws -> ExecutionConnectionReply {
        deepseekCalls += 1
        throw ExecutionConnectionFailure(code: "WRONG_PROVIDER")
    }
    func testSubscription(token: String, model: String) async throws -> ExecutionConnectionReply {
        subscriptionCalls += 1; seenToken = token; seenModel = model
        if delay { try await Task.sleep(nanoseconds: 80_000_000) }
        if let failure { throw ExecutionConnectionFailure(code: failure) }
        return .init(ok: true, code: "PASSED_TEXT_ONLY", model: model, ack: "CLAUDE_SUBSCRIPTION_CLI_OK", no_tools: true, request_count: 1,
                     cli: .init(exit_code: 0, signal: nil), cleanup: .init(temporary_removed: true, proxy_closed: true))
    }
}

@MainActor
func subscriptionConnectionSettingsChecks() async -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("subscription_connection_settings_" + name, passed)) }
    let suite = "com.claude-isolation-poc.subscription-connection-tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return [("subscription_connection_settings_suite_available", false)] }
    defer { defaults.removePersistentDomain(forName: suite) }
    let token = "sk-ant-oat01-connection-settings-fixture-token"
    let credentials = SubscriptionSettingsFixtureCredentials(token)
    let tester = SubscriptionConnectionSettingsFixture()
    let vm = ExecutionViewModel(store: .init(defaults: defaults), credentials: SubscriptionSettingsFixtureCredentials(), subscriptionCredentials: credentials, tester: tester)
    vm.provider = .claudeSubscription
    await vm.testConnection()
    let subscriptionCalls = await tester.subscriptionCalls, deepseekCalls = await tester.deepseekCalls
    let seenToken = await tester.seenToken, seenModel = await tester.seenModel
    check("subscription_loads_only_subscription_scope", credentials.loads == 1 && subscriptionCalls == 1 && deepseekCalls == 0 && seenToken == token && seenModel == "sonnet" && vm.apiKey.isEmpty)
    check("subscription_test_reports_distinct_success", vm.error == nil && !vm.testBusy && vm.testStatus?.contains("Claude 订阅") == true)
    vm.subscriptionToken = "not-an-oauth-token"
    await vm.testConnection()
    check("invalid_token_stops_before_provider", await tester.subscriptionCalls == 1 && vm.error == LocalCredentialFailure.invalidSubscriptionToken.message)
    let unavailable = SubscriptionSettingsFixtureCredentials()
    let missing = ExecutionViewModel(store: .init(defaults: defaults), credentials: SubscriptionSettingsFixtureCredentials(), subscriptionCredentials: unavailable, tester: tester)
    missing.provider = .claudeSubscription
    await missing.testConnection()
    check("missing_token_is_explicit_and_no_fallback", await tester.subscriptionCalls == 1 && missing.error?.contains("claude setup-token") == true && missing.testStatus == "连接测试未通过。")
    let deniedTester = SubscriptionConnectionSettingsFixture(failure: "SUBSCRIPTION_HTTP_401")
    let denied = ExecutionViewModel(store: .init(defaults: defaults), credentials: SubscriptionSettingsFixtureCredentials(), subscriptionCredentials: SubscriptionSettingsFixtureCredentials(token), tester: deniedTester)
    denied.provider = .claudeSubscription
    await denied.testConnection()
    check("subscription_auth_failure_does_not_fallback_to_deepseek", await deniedTester.deepseekCalls == 0 && denied.error == ExecutionConnectionFailure(code: "SUBSCRIPTION_HTTP_401").message)
    let delayedTester = SubscriptionConnectionSettingsFixture(delay: true)
    let stale = ExecutionViewModel(store: .init(defaults: defaults), credentials: SubscriptionSettingsFixtureCredentials(), subscriptionCredentials: SubscriptionSettingsFixtureCredentials(token), tester: delayedTester)
    stale.provider = .claudeSubscription
    let pending = Task { await stale.testConnection() }
    await Task.yield()
    stale.provider = .deepseekAPI
    await pending.value
    check("source_changed_during_test_rejects_stale_success", stale.error == ExecutionConnectionFailure(code: "CONFIG_CHANGED").message && stale.testStatus == "连接测试未通过。")
    return results
}
