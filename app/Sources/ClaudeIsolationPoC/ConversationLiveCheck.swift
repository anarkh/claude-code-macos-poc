import CryptoKit
import Foundation
import AppKit

/// One bounded benign text round-trip through exactly the same ViewModel used by the window.
/// Explicit invocation only; test history lives in memory, never in the user's sessions.
@MainActor
func runConversationLiveCheck(fixtureOnly: Bool) async -> Int32 {
    let schema = fixtureOnly ? "conversation-fixture-check/v1" : "conversation-live-check/v1"
    do {
        let configuration = try AppConfiguration.load()
        let translator = StdioTranslationProvider(configuration: configuration, fixtureOnly: fixtureOnly)
        let translationCredentials: any AppCredentialStoring = fixtureOnly ? MemoryAppCredentialStore() : FileCredentialStore(scope: .translation)
        let executionCredentials: any AppCredentialStoring = fixtureOnly ? MemoryAppCredentialStore() : FileCredentialStore(scope: .execution)
        let translation = TranslationViewModel(provider: translator, credentials: translationCredentials)
        let execution = ExecutionViewModel(credentials: executionCredentials)
        if fixtureOnly {
            translation.apiKey = "explicit-offline-ui-fixture-key"
            execution.apiKey = "explicit-offline-ui-fixture-key"
            execution.modelName = "deepseek-flash[1m]"
        }
        let memory = MemoryConversationStore()
        let chat = ConversationViewModel(translation: translation, execution: execution, translator: translator,
            provider: StdioChatProvider(configuration: configuration, fixtureOnly: fixtureOnly),
            store: memory, translationCredentials: translationCredentials,
            executionCredentials: executionCredentials, fixtureOnly: fixtureOnly)
        let original = "请只用一句英语简短解释 `print(\"hello\")`，并保留这段代码。不要使用工具。"
        chat.draft = original
        emitConversationRecord(["schema": schema, "stage": "automatic_input_and_cli", "status": "running", "fixture_only": fixtureOnly])
        chat.send()
        guard await waitForConversation({ !chat.isBusy }, seconds: 250),
              let user = chat.messages.first(where: { $0.role == .user }), user.state == .complete,
              user.originalText == original, user.text != original, user.text.contains("`print(\"hello\")`"),
              let assistant = chat.messages.first(where: { $0.role == .assistant }), assistant.state == .complete,
              !assistant.text.isEmpty, assistant.translation == nil else {
            chat.shutdown()
            emitConversationRecord(["schema": schema, "ok": false, "stage": "automatic_input_and_cli", "code": "CONVERSATION_ROUNDTRIP_FAILED",
                "diagnostic": chat.messages.first(where: { $0.error != nil })?.error ?? "回复未完成", "fixture_only": fixtureOnly])
            return 1
        }
        let raw = assistant.text
        emitConversationRecord(["schema": schema, "stage": "explicit_output_translation", "status": "running", "fixture_only": fixtureOnly])
        chat.translateMessage(assistant.id)
        guard await waitForConversation({ !chat.translatingMessageIDs.contains(assistant.id) }, seconds: 100),
              let completed = chat.messages.first(where: { $0.id == assistant.id }), completed.text == raw,
              let chinese = completed.translation, !chinese.isEmpty else {
            chat.shutdown()
            emitConversationRecord(["schema": schema, "ok": false, "stage": "explicit_output_translation", "code": "OUTPUT_TRANSLATION_FAILED", "fixture_only": fixtureOnly])
            return 1
        }
        chat.flushPersistence()
        let restarted = ConversationViewModel(translation: translation, execution: execution, translator: translator,
            provider: StdioChatProvider(configuration: configuration, fixtureOnly: fixtureOnly), store: memory,
            translationCredentials: translationCredentials, executionCredentials: executionCredentials, fixtureOnly: fixtureOnly)
        let restored = restarted.messages.first(where: { $0.id == assistant.id })
        let persisted = restored?.text == raw && restored?.translation == chinese
        emitConversationRecord(["schema": schema, "ok": persisted, "fixture_only": fixtureOnly,
            "automatic_input_translation": true, "translated_user_posted": true,
            "raw_output_preserved": true, "explicit_chinese_translation": true,
            "raw_output_sha256": SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined(),
            "raw_output_bytes": raw.utf8.count, "translation_bytes": chinese.utf8.count,
            "session_readback_equal": persisted, "user_history_written": false,
            "execution_model": execution.modelName, "translation_model": translation.modelName,
            "native_cli_used": !fixtureOnly, "project_execution_enabled": false, "claude_subscription_used": false])
        return persisted ? 0 : 1
    } catch {
        emitConversationRecord(["schema": schema, "ok": false, "code": "CONFIGURATION_UNAVAILABLE", "fixture_only": fixtureOnly])
        return 1
    }
}

@MainActor
private func waitForConversation(_ condition: () -> Bool, seconds: Double) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
        do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
    }
    return condition()
}

private func emitConversationRecord(_ record: [String: Any]) {
    do {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self)); fflush(stdout)
    } catch {
        print("{\"schema\":\"conversation-check/v1\",\"ok\":false,\"code\":\"RECORD_ENCODING_FAILED\"}")
    }
}

@MainActor
func runConversationWindowFixtureCheck(_ chat: ConversationViewModel) async {
    guard !chat.isBusy && chat.messages.isEmpty else { return }
    emitConversationRecord(["schema": "conversation-window-flow/v1", "stage": "send", "fixture_only": true])
    chat.draft = "请解释 `print(\"hello\")`。"
    chat.send()
    let ready = await waitForConversation({ !chat.isBusy }, seconds: 12)
    guard ready, let assistant = chat.messages.first(where: { $0.role == .assistant && $0.state == .complete }) else {
        chat.stop()
        emitConversationRecord(["schema": "conversation-window-flow/v1", "ok": false, "stage": "send", "code": "WINDOW_TEXT_FLOW_FAILED", "fixture_only": true])
        NSApplication.shared.terminate(nil); return
    }
    chat.translateMessage(assistant.id)
    let translated = await waitForConversation({ !chat.translatingMessageIDs.contains(assistant.id) }, seconds: 12)
    let completed = chat.messages.first { $0.id == assistant.id }
    let passed = translated && completed?.text == assistant.text && completed?.translation != nil
    emitConversationRecord(["schema": "conversation-window-flow/v1", "ok": passed, "fixture_only": true,
        "visible_own_windows": NSApplication.shared.windows.filter { $0.isVisible && $0.contentView != nil }.count,
        "raw_preserved": completed?.text == assistant.text, "chinese_translation": completed?.translation != nil,
        "real_model_called": false, "keychain_accessed": false, "user_history_written": false])
    NSApplication.shared.terminate(nil)
}
