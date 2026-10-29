import CryptoKit
import Foundation

private actor FixtureProvider: TranslationProviding {
    enum Behavior: Sendable { case valid, delayed, badHash, wrongOriginal, failed }
    let behavior: Behavior
    init(_ behavior: Behavior = .valid) { self.behavior = behavior }
    func translate(_ request: TranslationRequest) async throws -> TranslationReply {
        if behavior == .delayed { try await Task.sleep(nanoseconds: 80_000_000) }
        if behavior == .failed { throw TranslationFailure.code("TRANSLATION_PROCESS_FAILED") }
        let text = request.target == "zh" ? "已完成：`foo()`" : request.target == "ja" ? "説明してください `foo()`" : "Please explain `foo()`"
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(ok: true, request_id: UUID().uuidString.lowercased(), original: behavior == .wrongOriginal ? "wrong" : request.text, translated: text, revision: 1, translation_sha256: behavior == .badHash ? String(repeating: "0", count: 64) : digest, requires_confirmation: request.operation == "translate_input", error_code: nil, fixture_only: true)
    }
}

@MainActor
func runSelfTests() async -> Int32 {
    var checked = 0
    var failures: [String] = []
    func check(_ condition: Bool, _ name: String) {
        checked += 1
        if !condition { failures.append(name) }
    }
    func make(_ behavior: FixtureProvider.Behavior = .valid) -> TranslationViewModel {
        let model = TranslationViewModel(provider: FixtureProvider(behavior))
        model.apiKey = "poc-ui-only-fake-key"
        model.inputText = "请解释 `foo()`"
        return model
    }
    for (name, passed) in executionConfigurationChecks() { check(passed, name) }
    for (name, passed) in executionViewModelChecks() { check(passed, name) }
    for (name, passed) in localCredentialStoreChecks() { check(passed, name) }
    for (name, passed) in subscriptionAccountStoreChecks() { check(passed, name) }
    for (name, passed) in subscriptionQuotaChecks() { check(passed, name) }
    for (name, passed) in await subscriptionAccountsModelChecks() { check(passed, name) }
    for (name, passed) in await subscriptionAccountsIntegrationChecks() { check(passed, name) }
    for (name, passed) in installationIdentityChecks() { check(passed, name) }
    for (name, passed) in deviceIdentitySettingsChecks() { check(passed, name) }
    for (name, passed) in diagnosticsSettingsChecks() { check(passed, name) }
    for (name, passed) in translationCredentialChecks() { check(passed, name) }
    for (name, passed) in credentialSettingsRestoreChecks() { check(passed, name) }
    for (name, passed) in subscriptionSettingsChecks() { check(passed, name) }
    for (name, passed) in await subscriptionConnectionSettingsChecks() { check(passed, name) }
    for (name, passed) in await executionCredentialConnectionChecks() { check(passed, name) }
    for (name, passed) in translationConfigurationChecks() { check(passed, name) }
    for (name, passed) in networkConfigurationChecks() { check(passed, name) }
    for (name, passed) in browserProxyGatewayChecks() { check(passed, name) }
    for (name, passed) in await browserClipboardTransportChecks() { check(passed, name) }
    for (name, passed) in browserClipboardInteractionChecks() { check(passed, name) }
    for (name, passed) in await browserRuntimeLifecycleChecks() { check(passed, name) }
    for (name, passed) in await browserRuntimeStorageChecks() { check(passed, name) }
    for (name, passed) in runtimeProfileChecks() { check(passed, name) }
    for (name, passed) in runtimeTimeZoneCatalogChecks() { check(passed, name) }
    for (name, passed) in conversationStoreChecks() { check(passed, name) }
    for (name, passed) in projectDirectoryChecks() { check(passed, name) }
    for (name, passed) in textSkillsChecks() { check(passed, name) }
    for (name, passed) in chatExecutionChecks() { check(passed, name) }
    for (name, passed) in projectChatBridgeChecks() { check(passed, name) }
    for (name, passed) in requestTraceChecks() { check(passed, name) }
    for (name, passed) in await conversationViewModelChecks() { check(passed, name) }
    for (name, passed) in await executionConnectionViewModelChecks() { check(passed, name) }
    for (name, passed) in await loginResetLifecycleChecks() { check(passed, name) }
    for (name, passed) in ownedRuntimeCleanupChecks() { check(passed, name) }
    for (name, passed) in await claudeLoginResetChecks() { check(passed, name) }
    for (name, passed) in await applicationTerminationChecks() { check(passed, name) }
    for (name, passed) in await runtimePackageChecks() { check(passed, name) }
    for (name, passed) in await runtimeUpdateChecks() { check(passed, name) }
    for (name, passed) in await localRuntimePackageChecks() { check(passed, name) }
    for (name, passed) in await officialRuntimeVersionChecks() { check(passed, name) }
    do {
        for (name, passed) in try OfficialRuntimeUpdateChecks.run() { check(passed, name) }
    } catch { check(false, "official_update_checks_failed") }
    let model = make()
    check(!model.canSendToClaude && !model.canConfirm, "initial_gate_closed")
    await model.translateInput()
    check(model.inputTranslation?.translated == "Please explain `foo()`" && model.canConfirm, "input_response_accepted")
    model.confirmInput()
    check(model.inputIsConfirmed, "current_translation_confirmed")
    check(!model.canSendToClaude, "confirmed_does_not_open_execution")
    model.inputText += " 更新"
    check(!model.inputIsConfirmed && model.inputTranslation == nil, "input_change_invalidates_confirmation")
    await model.translateInput(); model.confirmInput(); model.targetLanguage = .japanese
    check(!model.inputIsConfirmed && model.inputTranslation == nil, "target_change_invalidates_confirmation")
    await model.translateInput(); model.confirmInput(); model.modelName = "changed-model"
    check(!model.inputIsConfirmed && model.inputTranslation == nil, "model_change_invalidates_confirmation")
    await model.translateInput(); model.confirmInput(); model.endpoint = "https://example.invalid/chat/completions"
    check(!model.inputIsConfirmed && model.inputTranslation == nil, "endpoint_change_invalidates_confirmation")
    await model.translateInput(); model.confirmInput(); model.apiKey = "another-ui-fake-key"
    check(!model.inputIsConfirmed && model.inputTranslation == nil, "key_change_invalidates_confirmation")
    model.outputText = "Finished: `foo()`"
    await model.translateOutput()
    check(model.outputTranslation?.translated == "已完成：`foo()`" && model.outputText == "Finished: `foo()`", "output_response_preserves_original")
    model.outputText += " edited"
    check(model.outputTranslation == nil, "output_change_invalidates_translation")
    let missingKey = TranslationViewModel(provider: FixtureProvider())
    missingKey.inputText = "中文"
    await missingKey.translateInput()
    check(missingKey.inputError != nil && !missingKey.canConfirm, "missing_key_fails_closed")
    let invalidEndpoint = make(); invalidEndpoint.endpoint = "http://example.invalid"
    await invalidEndpoint.translateInput()
    check(invalidEndpoint.inputError != nil && !invalidEndpoint.canConfirm, "invalid_endpoint_fails_closed")
    let badHash = make(.badHash); await badHash.translateInput()
    check(badHash.inputError != nil && badHash.inputTranslation == nil, "hash_mismatch_rejected")
    let wrongOriginal = make(.wrongOriginal); await wrongOriginal.translateInput()
    check(wrongOriginal.inputError != nil && wrongOriginal.inputTranslation == nil, "original_mismatch_rejected")
    let failed = make(.failed); await failed.translateInput()
    check(failed.inputError != nil && !failed.canConfirm, "translation_failure_cannot_confirm")
    let stale = make(.delayed)
    let translating = Task { await stale.translateInput() }
    await Task.yield()
    check(stale.inputBusy && !stale.canConfirm && !stale.canSendToClaude, "inflight_cannot_confirm_or_send")
    stale.inputText = "新的原文"
    await translating.value
    check(stale.inputTranslation == nil && !stale.inputIsConfirmed && !stale.inputBusy, "stale_async_result_discarded")
    let request = TranslationRequest(request_id: "local-invocation", operation: "translate_input", text: "中文", target: "en", model: .init(endpoint: "https://example.invalid", model: "test", apiKey: "fake"))
    do {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        check(object?["request_id"] == nil && object?["text"] as? String == "中文", "bridge_payload_does_not_override_request_id")
    } catch { check(false, "bridge_payload_encoding") }
    let latestCheckDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-ui-latest-\(UUID().uuidString)")
    do {
        let evidenceDirectory = latestCheckDirectory.appendingPathComponent("host/evidence")
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let number = "9999999999999999999999999999999999999"
        try Data("{}".utf8).write(to: evidenceDirectory.appendingPathComponent("native-\(number)-relay-chain.json"))
        let status = EvidenceStatus.load(projectRoot: latestCheckDirectory.path)
        let replay = ExecutionReplay.load(projectRoot: latestCheckDirectory.path)
        check(status.run == replay.run && status.run == "native-\(number)" && !replay.isAvailable,
              "evidence_and_replay_choose_same_latest_even_above_int_range")
        try FileManager.default.removeItem(at: latestCheckDirectory)
    } catch {
        check(false, "latest_evidence_check_setup_or_cleanup")
    }
    if let marker = CommandLine.arguments.firstIndex(of: "--fixture-project-root"), marker + 1 < CommandLine.arguments.count {
        let root = CommandLine.arguments[marker + 1]
        for (name, passed) in executionReplayChecks(projectRoot: root) {
            check(passed, name)
        }
        if let nodeMarker = CommandLine.arguments.firstIndex(of: "--fixture-node"), nodeMarker + 1 < CommandLine.arguments.count {
            let configuration = AppConfiguration(projectRoot: root, nodeExecutable: CommandLine.arguments[nodeMarker + 1])
            for (name, passed) in await chatExecutionFixtureChecks(configuration: configuration) { check(passed, name) }
            for (name, passed) in await loginResetStdioChecks(configuration: configuration) { check(passed, name) }
            for (name, passed) in await networkBridgeChecks(configuration: configuration) { check(passed, name) }
            for (name, passed) in await subscriptionQuotaBridgeChecks(configuration: configuration) { check(passed, name) }
            for (name, passed) in await runtimeBridgeChecks(configuration: configuration) { check(passed, name) }
            for (name, passed) in await installationIdentityBridgeChecks(configuration: configuration) { check(passed, name) }
            for (name, passed) in await projectStdioBridgeChecks(configuration: configuration) { check(passed, name) }
            let liveFixture = TranslationViewModel(provider: StdioTranslationProvider(configuration: configuration, fixtureOnly: true))
            liveFixture.apiKey = "fixture-only-value-not-sent-to-real-service"
            liveFixture.inputText = "请解释 `foo()`"
            await liveFixture.translateInput()
            check(liveFixture.inputTranslation?.translated == "Please explain `foo()`" && liveFixture.inputError == nil, "real_stdio_fixture_input")
            liveFixture.confirmInput()
            check(liveFixture.inputIsConfirmed && !liveFixture.canSendToClaude, "real_stdio_fixture_confirm_gate")
            liveFixture.outputText = "Finished: `foo()`"
            await liveFixture.translateOutput()
            check(liveFixture.outputTranslation != nil && liveFixture.outputError == nil, "real_stdio_fixture_output")
            let status = EvidenceStatus.load(projectRoot: root)
            check(status.finalGate == "完整隔离准入未完成", "evidence_never_opens_full_gate")
        } else { check(false, "fixture_node_argument_required") }
    }
    let result: [String: Any] = ["schema": "mac-app-self-tests/v1", "status": failures.isEmpty ? "passed" : "failed", "checks": checked, "failures": failures, "real_model_called": false, "credential_test_scope": "synthetic_local_files", "keychain_ipc_blocking": "not_tested_by_swift_suite", "project_execution_enabled": false]
    do {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } catch { print("{\"schema\":\"mac-app-self-tests/v1\",\"status\":\"serialization_failed\"}"); return 1 }
    return failures.isEmpty ? 0 : 1
}
