import CryptoKit
import Foundation

private func emitDeepSeekRecord(_ record: [String: Any]) {
    do {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self)); fflush(stdout)
    } catch { print("{\"ok\":false,\"code\":\"RECORD_ENCODING_FAILED\"}") }
}

@MainActor
func configureOfficialDeepSeek() -> Int32 {
    var executionKeySaved = false, translationKeySaved = false
    do {
        let data = try FileHandle.standardInput.read(upToCount: 4_097) ?? Data()
        guard data.count <= 4_096, let raw = String(data: data, encoding: .utf8) else {
            throw ExecutionConnectionFailure(code: "INVALID_KEY_INPUT")
        }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(of: "^sk-[A-Za-z0-9_-]{20,200}$", options: .regularExpression) != nil else {
            throw ExecutionConnectionFailure(code: "INVALID_KEY_INPUT")
        }
        let executionKeys = FileCredentialStore(scope: .execution), translationKeys = FileCredentialStore(scope: .translation)
        try executionKeys.save(key); executionKeySaved = true
        try translationKeys.save(key); translationKeySaved = true
        guard try executionKeys.load() == key, try translationKeys.load() == key else {
            throw ExecutionConnectionFailure(code: "CREDENTIAL_READBACK_FAILED")
        }
        let execution = ExecutionModelConfiguration(baseURL: "https://api.deepseek.com/anthropic", model: "deepseek-flash[1m]")
        let translation = TranslationPublicConfiguration(endpoint: "https://api.deepseek.com/chat/completions", model: "deepseek-flash")
        let executionStore = ExecutionConfigurationStore(), translationStore = TranslationConfigurationStore()
        try executionStore.save(execution); try translationStore.save(translation)
        guard executionStore.load() == .configured(execution), translationStore.load() == .configured(translation) else {
            throw ExecutionConnectionFailure(code: "CONFIG_READBACK_FAILED")
        }
        emitDeepSeekRecord(["schema": "deepseek-app-setup/v2", "ok": true, "execution_model": execution.model, "translation_model": translation.model,
                           "credential_storage": "app-local-file", "execution_credential_saved": true, "translation_credential_saved": true, "credential_readback_matched": true,
                           "project_execution_enabled": false])
        return 0
    } catch {
        emitDeepSeekRecord(["schema": "deepseek-app-setup/v2", "ok": false, "code": "SETUP_FAILED",
                           "credential_storage": "app-local-file", "execution_credential_saved": executionKeySaved, "translation_credential_saved": translationKeySaved])
    }
    return 1
}

@MainActor
func runDeepSeekLiveCheck() async -> Int32 {
    var cli: [String: Any] = ["ok": false, "code": "NOT_TESTED"]
    var translations: [[String: Any]] = []
    do {
        let configuration = try AppConfiguration.load()
        guard case .configured(let execution) = ExecutionConfigurationStore().load(),
              execution.baseURL == "https://api.deepseek.com/anthropic", execution.model == "deepseek-flash[1m]",
              case .configured(let translation) = TranslationConfigurationStore().load(),
              translation.endpoint == "https://api.deepseek.com/chat/completions", translation.model == "deepseek-flash",
              let executionKey = try FileCredentialStore(scope: .execution).load(),
              let translationKey = try FileCredentialStore(scope: .translation).load() else {
            throw ExecutionConnectionFailure(code: "MISSING_CONFIG_OR_KEY")
        }
        emitDeepSeekRecord(["schema": "deepseek-live-check-progress/v1", "stage": "claude_cli", "status": "running"])
        do {
            let result = try await StdioExecutionConnectionTester(configuration: configuration).test(apiKey: executionKey, model: execution.model)
            cli = ["ok": true, "model": result.model, "ack": result.ack ?? "", "no_tools": result.no_tools,
                   "request_count": result.request_count ?? 0, "cli_exit": result.cli.exit_code ?? -1,
                   "temporary_removed": result.cleanup.temporary_removed, "proxy_closed": result.cleanup.proxy_closed]
        } catch let failure as ExecutionConnectionFailure { cli = ["ok": false, "code": failure.code] }
        catch { cli = ["ok": false, "code": "CLI_CHECK_FAILED"] }
        emitDeepSeekRecord(["schema": "deepseek-live-check-progress/v1", "stage": "claude_cli", "ok": cli["ok"] ?? false])
        let provider = StdioTranslationProvider(configuration: configuration)
        for (operation, target, text) in [("translate_input", "en", "请解释 `print(\"hello\")`。"),
                                           ("translate_input", "ja", "请解释 `print(\"hello\")`。"),
                                           ("translate_output", "zh", "Completed successfully. Keep `print(\"hello\")` unchanged.")] {
            emitDeepSeekRecord(["schema": "deepseek-live-check-progress/v1", "stage": "translation", "target": target, "status": "running"])
            let request = TranslationRequest(request_id: UUID().uuidString.lowercased(), operation: operation, text: text, target: target,
                                             model: .init(endpoint: translation.endpoint, model: translation.model, apiKey: translationKey))
            do {
                let result = try await provider.translate(request)
                let translated = result.translated ?? ""
                let digest = SHA256.hash(data: Data(translated.utf8)).map { String(format: "%02x", $0) }.joined()
                let accepted = result.ok && result.fixture_only == false && result.original == text &&
                    translated.contains("`print(\"hello\")`") && result.translation_sha256 == digest &&
                    result.request_id.flatMap(UUID.init(uuidString:)) != nil && result.requires_confirmation == (operation == "translate_input")
                translations.append(["target": target, "ok": accepted, "model": translation.model,
                                     "translated": translated.replacingOccurrences(of: translationKey, with: "[REDACTED]"),
                                     "code": result.error_code ?? (accepted ? "OK" : "TRANSLATION_CHECK_FAILED")])
            } catch { translations.append(["target": target, "ok": false, "code": "TRANSLATION_CHECK_FAILED"]) }
        }
    } catch {
        emitDeepSeekRecord(["schema": "deepseek-live-check/v1", "ok": false, "code": "MISSING_CONFIG_OR_KEY", "project_execution_enabled": false])
        return 1
    }
    let passed = cli["ok"] as? Bool == true && translations.count == 3 && translations.allSatisfy { $0["ok"] as? Bool == true }
    emitDeepSeekRecord(["schema": "deepseek-live-check/v1", "ok": passed, "cli": cli, "translation": translations,
                       "provider": "DeepSeek", "claude_subscription_used": false, "project_execution_enabled": false])
    return passed ? 0 : 1
}
