import Foundation

func chatExecutionChecks() -> [(String, Bool)] {
    let requestID = UUID().uuidString
    let model = "deepseek-flash[1m]"
    let key = "explicit-offline-fixture-key"
    let request = ChatRequest(request_id: requestID, apiKey: key, model: model,
                              messages: [.init(role: "user", text: "Hello")])
    let base: [String: Any] = ["schema": "deepseek-text-chat-event/v1", "request_id": requestID,
                              "model": model, "fixture_only": false]
    func event(_ type: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var value = base
        value["type"] = type
        value.merge(fields) { _, new in new }
        return value
    }
    let started = event("started", ["no_tools": true])
    let raw = "  Hello\n```swift\nprint(\"你好 🌏\")\n```\n  "
    let delta = event("delta", ["text": raw])
    let completed = event("completed", ["text": raw, "no_tools": true, "cli_exit": 0,
                                          "cli_signal": NSNull(), "temporary_removed": true,
                                          "proxy_closed": true, "request_count": 1])
    var results: [(String, Bool)] = []
    func rejects(_ name: String, _ values: [[String: Any]]) {
        var parser = ChatEventParser(requestID: requestID, model: model, fixtureOnly: false)
        do {
            for value in values { _ = try parser.consume(JSONSerialization.data(withJSONObject: value)) }
            results.append((name, false))
        } catch { results.append((name, true)) }
    }
    func changed(_ value: [String: Any], _ key: String, _ replacement: Any) -> [String: Any] {
        var value = value
        value[key] = replacement
        return value
    }
    func requestRejected(_ name: String, _ value: ChatRequest) {
        do { try value.validate(); results.append((name, false)) }
        catch { results.append((name, true)) }
    }
    do {
        try request.validate()
        let encoded = try JSONEncoder().encode(request)
        let value = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        results.append(("chat_request_serializes_key_only_in_stdin_payload", value?["schema"] as? String == "deepseek-text-chat/v1" && value?["apiKey"] as? String == key))
        var parser = ChatEventParser(requestID: requestID, model: model, fixtureOnly: false)
        let start = try parser.consume(JSONSerialization.data(withJSONObject: started))
        let text = try parser.consume(JSONSerialization.data(withJSONObject: delta))
        let receipt = try parser.consume(JSONSerialization.data(withJSONObject: completed))
        results.append(("chat_stream_preserves_unicode_code_and_all_whitespace", start == .started && text == .delta(raw)))
        let accepted = try parser.finish(processSucceeded: true)
        results.append(("chat_completion_waits_for_eof_and_process_exit", receipt == nil && accepted == .completed(raw)))
        do { _ = try parser.finish(processSucceeded: false); results.append(("chat_valid_receipt_rejects_nonzero_process_exit", false)) }
        catch { results.append(("chat_valid_receipt_rejects_nonzero_process_exit", true)) }
    } catch { results.append(("chat_valid_protocol_accepts", false)) }
    rejects("chat_stream_rejects_delta_before_native_started", [delta])
    rejects("chat_stream_rejects_repeated_started", [started, started])
    rejects("chat_stream_rejects_foreign_request_id", [changed(started, "request_id", UUID().uuidString)])
    rejects("chat_stream_rejects_model_mismatch", [changed(started, "model", "deepseek-flash")])
    rejects("chat_stream_rejects_schema_mismatch", [changed(started, "schema", "unknown/v1")])
    rejects("chat_stream_rejects_fixture_in_production", [changed(started, "fixture_only", true)])
    rejects("chat_stream_rejects_numeric_fixture_flag", [changed(started, "fixture_only", 0)])
    rejects("chat_stream_rejects_numeric_no_tools_flag", [changed(started, "no_tools", 1)])
    rejects("chat_stream_rejects_extra_fields", [changed(started, "diagnostic", "untrusted")])
    rejects("chat_stream_rejects_empty_delta", [started, event("delta", ["text": ""])])
    rejects("chat_stream_rejects_unknown_event", [event("mystery")])
    rejects("chat_stream_rejects_completion_without_deltas", [started, completed])
    rejects("chat_stream_rejects_changed_completion_text", [started, delta, changed(completed, "text", raw.trimmingCharacters(in: .whitespacesAndNewlines))])
    rejects("chat_stream_rejects_unverified_tools", [started, delta, changed(completed, "no_tools", false)])
    rejects("chat_stream_rejects_failed_cli_exit_receipt", [started, delta, changed(completed, "cli_exit", 1)])
    rejects("chat_stream_rejects_boolean_cli_exit_receipt", [started, delta, changed(completed, "cli_exit", false)])
    rejects("chat_stream_rejects_cli_signal_receipt", [started, delta, changed(completed, "cli_signal", "SIGTERM")])
    rejects("chat_stream_rejects_missing_temporary_cleanup", [started, delta, changed(completed, "temporary_removed", false)])
    rejects("chat_stream_rejects_missing_proxy_cleanup", [started, delta, changed(completed, "proxy_closed", false)])
    rejects("chat_stream_rejects_zero_provider_requests", [started, delta, changed(completed, "request_count", 0)])
    rejects("chat_stream_rejects_excess_provider_requests", [started, delta, changed(completed, "request_count", 4)])
    rejects("chat_stream_rejects_delta_after_completed", [started, delta, completed, delta])
    rejects("chat_stream_rejects_repeated_completion", [started, delta, completed, completed])
    rejects("chat_stream_rejects_unknown_error_message", [event("error", ["code": "PRIVATE_SECRET_MUST_NOT_BE_EXPOSED"])])
    rejects("chat_stream_rejects_error_with_raw_details", [event("error", ["code": "PROVIDER_HTTP_401", "details": "private"])])
    rejects("chat_stream_bounds_cumulative_text_bytes", [started, event("delta", ["text": String(repeating: "a", count: 524_289)])])
    do {
        let parser = ChatEventParser(requestID: requestID, model: model, fixtureOnly: false)
        _ = try parser.finish(processSucceeded: true)
        results.append(("chat_stream_rejects_eof_without_completion", false))
    } catch { results.append(("chat_stream_rejects_eof_without_completion", true)) }
    do {
        var parser = ChatEventParser(requestID: requestID, model: model, fixtureOnly: false)
        _ = try parser.consume(JSONSerialization.data(withJSONObject: event("error", ["code": "PROVIDER_HTTP_401"])))
        results.append(("chat_stream_recognizes_safe_actionable_error", false))
    } catch let failure as ChatFailure {
        results.append(("chat_stream_recognizes_safe_actionable_error", failure.message.contains("API Key")))
    } catch { results.append(("chat_stream_recognizes_safe_actionable_error", false)) }
    requestRejected("chat_request_rejects_invalid_id", .init(request_id: "invalid", apiKey: key, model: model, messages: request.messages))
    requestRejected("chat_request_rejects_other_model", .init(request_id: requestID, apiKey: key, model: "other", messages: request.messages))
    requestRejected("chat_request_rejects_missing_key", .init(request_id: requestID, apiKey: "", model: model, messages: request.messages))
    requestRejected("chat_request_rejects_control_character_key", .init(request_id: requestID, apiKey: key + "\n", model: model, messages: request.messages))
    let token = "sk-ant-oat01-offline-request-fixture"
    do {
        let subscription = ChatRequest(request_id: requestID, model: "sonnet", messages: request.messages,
                                       provider: .claudeSubscription, subscriptionToken: token)
        try subscription.validate()
        let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(subscription)) as? [String: Any]
        results.append(("subscription_request_uses_exclusive_oauth_payload", fields?["provider"] as? String == "claude-subscription" && fields?["subscriptionToken"] as? String == token && fields?["apiKey"] == nil))
    } catch { results.append(("subscription_request_uses_exclusive_oauth_payload", false)) }
    requestRejected("subscription_request_rejects_api_key_billing_overlap", .init(request_id: requestID, apiKey: key, model: "sonnet", messages: request.messages, provider: .claudeSubscription, subscriptionToken: token))
    requestRejected("api_request_rejects_subscription_token_overlap", .init(request_id: requestID, apiKey: key, model: model, messages: request.messages, subscriptionToken: token))
    requestRejected("subscription_request_rejects_missing_token", .init(request_id: requestID, model: "sonnet", messages: request.messages, provider: .claudeSubscription))
    requestRejected("subscription_request_rejects_deepseek_model", .init(request_id: requestID, model: model, messages: request.messages, provider: .claudeSubscription, subscriptionToken: token))
    requestRejected("subscription_request_rejects_api_key_in_token_field", .init(request_id: requestID, model: "sonnet", messages: request.messages, provider: .claudeSubscription, subscriptionToken: key))
    requestRejected("subscription_request_rejects_control_characters", .init(request_id: requestID, model: "sonnet", messages: request.messages, provider: .claudeSubscription, subscriptionToken: token + "\n"))
    requestRejected("subscription_request_rejects_oversize_token", .init(request_id: requestID, model: "sonnet", messages: request.messages, provider: .claudeSubscription, subscriptionToken: "sk-ant-oat01-" + String(repeating: "a", count: 4096)))
    for code in ["SUBSCRIPTION_HTTP_401", "SUBSCRIPTION_HTTP_403", "SUBSCRIPTION_HTTP_429", "SUBSCRIPTION_PROTOCOL_REJECTED", "CREDENTIAL_MODE_MISMATCH"] {
        var parser = ChatEventParser(requestID: requestID, model: model, fixtureOnly: false)
        do {
            _ = try parser.consume(JSONSerialization.data(withJSONObject: event("error", ["code": code])))
            results.append(("subscription_parser_recognizes_\(code)", false))
        } catch let failure as ChatFailure {
            if case .code(let received) = failure { results.append(("subscription_parser_recognizes_\(code)", received == code)) }
        } catch { results.append(("subscription_parser_recognizes_\(code)", false)) }
    }
    requestRejected("chat_request_rejects_non_alternating_history", .init(request_id: requestID, apiKey: key, model: model, messages: [.init(role: "user", text: "one"), .init(role: "user", text: "two"), .init(role: "user", text: "three")]))
    requestRejected("chat_request_rejects_tool_history", .init(request_id: requestID, apiKey: key, model: model, messages: [.init(role: "tool", text: "one")]))
    requestRejected("chat_request_rejects_even_history", .init(request_id: requestID, apiKey: key, model: model, messages: [.init(role: "user", text: "one"), .init(role: "assistant", text: "two")]))
    requestRejected("chat_request_rejects_oversize_history", .init(request_id: requestID, apiKey: key, model: model, messages: [.init(role: "user", text: String(repeating: "a", count: 131_073))]))
    let context = TextSkillContext(name: "writing", content: "Use concise wording. 保留代码。")
    do {
        let selected = ChatRequest(request_id: requestID, apiKey: key, model: model, messages: request.messages, text_skills: [context])
        try selected.validate()
        let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selected)) as? [String: Any]
        let textSkills = fields?["text_skills"] as? [[String: String]]
        results.append(("chat_request_serializes_text_skills_without_changing_messages", textSkills == [["name": context.name, "content": context.content]] && selected.messages == request.messages))
    } catch { results.append(("chat_request_serializes_text_skills_without_changing_messages", false)) }
    requestRejected("chat_request_rejects_empty_skill_body", .init(request_id: requestID, apiKey: key, model: model, messages: request.messages, text_skills: [.init(name: "empty", content: " \n")]))
    requestRejected("chat_request_rejects_duplicate_skills", .init(request_id: requestID, apiKey: key, model: model, messages: request.messages, text_skills: [context, context]))
    requestRejected("chat_request_rejects_skill_format_characters", .init(request_id: requestID, apiKey: key, model: model, messages: request.messages, text_skills: [.init(name: "bad\u{200B}", content: "text")]))
    requestRejected("chat_request_bounds_skill_unicode_scalars", .init(request_id: requestID, apiKey: key, model: model, messages: request.messages, text_skills: [.init(name: String(repeating: "e\u{0301}", count: 41), content: "text")]))
    requestRejected("chat_request_bounds_skill_body_bytes", .init(request_id: requestID, apiKey: key, model: model, messages: request.messages, text_skills: [.init(name: "large", content: String(repeating: "中", count: 10_923))]))
    requestRejected("chat_request_bounds_total_skill_context_including_names", .init(request_id: requestID, apiKey: key, model: model, messages: request.messages, text_skills: [.init(name: "one", content: String(repeating: "a", count: 32_768)), .init(name: "two", content: String(repeating: "b", count: 32_768))]))
    requestRejected("chat_request_bounds_enabled_skill_count", .init(request_id: requestID, apiKey: key, model: model, messages: request.messages, text_skills: (0..<9).map { .init(name: "skill-\($0)", content: "text") }))
    let beforeLaunch = OwnedProcessController()
    beforeLaunch.cancel()
    do { try beforeLaunch.install(Process()); results.append(("chat_cancellation_before_launch_blocks_process_install", false)) }
    catch { results.append(("chat_cancellation_before_launch_blocks_process_install", beforeLaunch.isCancelled && !beforeLaunch.isTimedOut)) }
    let raced = OwnedProcessController()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try raced.install(process)
        raced.cancel()
        try process.run()
        raced.didStart()
        process.waitUntilExit()
        raced.finish()
        results.append(("chat_cancellation_racing_launch_terminates_only_owned_process", raced.isCancelled && !process.isRunning && process.terminationStatus != 0))
    } catch { results.append(("chat_cancellation_racing_launch_terminates_only_owned_process", false)) }
    return results
}

func chatExecutionFixtureChecks(configuration: AppConfiguration) async -> [(String, Bool)] {
    let provider = StdioChatProvider(configuration: configuration, fixtureOnly: true)
    let request = ChatRequest(request_id: UUID().uuidString, apiKey: "explicit-offline-fixture-key",
                              model: "deepseek-flash[1m]", messages: [.init(role: "user", text: "你好")])
    var results: [(String, Bool)] = []
    do {
        var events: [ChatEvent] = []
        for try await event in provider.events(for: request) { events.append(event) }
        let full = "Offline text fixture. 离线测试回复：你好，世界 🌏。"
        let textEvents = events.filter { if case .requestTrace = $0 { return false }; return true }
        results.append(("chat_stdio_fixture_streams_ordered_raw_unicode", textEvents == [.started, .delta("Offline text fixture. "), .delta("离线测试回复："), .delta("你好，世界 🌏。"), .completed(full)]))
    } catch { results.append(("chat_stdio_fixture_streams_ordered_raw_unicode", false)) }
    do {
        let subscription = ChatRequest(request_id: UUID().uuidString, model: "sonnet", messages: request.messages,
                                       provider: .claudeSubscription, subscriptionToken: "sk-ant-oat01-offline-stdio-fixture")
        var final: String?
        for try await event in provider.events(for: subscription) { if case .completed(let text) = event { final = text } }
        results.append(("subscription_stdio_fixture_preserves_raw_output", final == "Offline text fixture. 离线测试回复：你好，世界 🌏。"))
    } catch { results.append(("subscription_stdio_fixture_preserves_raw_output", false)) }

    do {
        let selected = ChatRequest(request_id: UUID().uuidString, apiKey: "explicit-offline-fixture-key",
                                   model: request.model, messages: request.messages,
                                   text_skills: [.init(name: "fixture-style", content: "Keep replies concise.")])
        var final: String?
        for try await event in provider.events(for: selected) {
            if case .completed(let text) = event { final = text }
        }
        results.append(("chat_stdio_fixture_accepts_app_selected_text_skills", final?.contains("Applied text skills: fixture-style") == true))
    } catch { results.append(("chat_stdio_fixture_accepts_app_selected_text_skills", false)) }

    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("claude-chat-protocol-check-\(UUID().uuidString)")
    do {
        let sdk = temporary.appendingPathComponent("sdk")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        // A still-running, owned fake bridge sends an invalid envelope. Failure
        // cleanup must retain the validation error instead of claiming Stop.
        try Data("process.stdin.resume(); process.stdout.write('{\"schema\":\"invalid\"}\\n'); setInterval(() => {}, 1000);\n".utf8)
            .write(to: sdk.appendingPathComponent("deepseek-text-chat.mjs"))
        let malformed = StdioChatProvider(configuration: .init(projectRoot: temporary.path, nodeExecutable: configuration.nodeExecutable), fixtureOnly: true)
        do {
            for try await _ in malformed.events(for: request) {}
            results.append(("chat_failure_cleanup_preserves_protocol_error", false))
        } catch let failure as ChatFailure {
            if case .code(let code) = failure {
                results.append(("chat_failure_cleanup_preserves_protocol_error", code == "CHAT_RESPONSE_INVALID"))
            }
        } catch { results.append(("chat_failure_cleanup_preserves_protocol_error", false)) }
    } catch { results.append(("chat_failure_cleanup_preserves_protocol_error", false)) }
    do {
        try FileManager.default.removeItem(at: temporary)
        results.append(("chat_protocol_fixture_temporary_removed", !FileManager.default.fileExists(atPath: temporary.path)))
    } catch { results.append(("chat_protocol_fixture_temporary_removed", false)) }
    return results
}
