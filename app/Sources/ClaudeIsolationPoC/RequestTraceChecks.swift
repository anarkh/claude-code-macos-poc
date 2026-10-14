import Foundation

/// Synthetic request snapshots exercise the wire boundary without network access.
func requestTraceChecks() -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    let runID = UUID(), model = "deepseek-flash[1m]"
    let trace = requestTraceFixture(runID: runID)
    func check(_ name: String, _ result: Bool) { checks.append(("request_trace_" + name, result)) }
    func object(_ value: ChatRequestTrace) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
    func event(_ trace: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema": "deepseek-text-chat-event/v1", "request_id": runID.uuidString,
            "model": model, "fixture_only": false, "type": "request_trace", "trace": trace])
    }
    func rejects(_ name: String, knownSecrets: [String] = [], mutate: (inout [String: Any]) -> Void) {
        do {
            var value = try object(trace); mutate(&value)
            var parser = ChatEventParser(requestID: runID.uuidString, model: model, fixtureOnly: false, knownSecrets: knownSecrets)
            _ = try parser.consume(event(value)); check(name, false)
        } catch { check(name, true) }
    }
    do {
        try trace.validate(runID: runID)
        let layout = conversationLayoutFixtureStore().snapshot
        try layout.validate()
        let decodedLayout = try JSONDecoder().decode(ConversationSnapshot.self, from: JSONEncoder().encode(layout))
        check("three_attempt_ui_fixture_obeys_persisted_contract", decodedLayout == layout)
        check("full_json_preserves_unicode_whitespace_and_cli_metadata", trace.body.contains("你好 🌏") && trace.body.contains("metadata") && trace.body.hasPrefix("{\n"))
        let request = try event(object(trace))
        let responseTrace = requestTraceFixture(runID: runID, phase: .response)
        var parser = ChatEventParser(requestID: runID.uuidString, model: model, fixtureOnly: false)
        check("request_event_has_one_snapshot", try parser.consume(request) == .requestTrace(trace))
        check("terminal_event_updates_same_attempt_without_dropping_body", try parser.consume(event(object(responseTrace))) == .requestTrace(responseTrace) && trace.hasSameRequest(as: responseTrace))
        do { _ = try parser.consume(event(object(responseTrace))); check("terminal_replay_rejected", false) }
        catch { check("terminal_replay_rejected", true) }
        let cancelled = trace.markingInterrupted()
        try cancelled.validate(runID: runID)
        check("app_interruption_keeps_body_and_unknown_elapsed", cancelled.body == trace.body && cancelled.outcome == "cancelled" && cancelled.durationMS == nil)
        let restored = try JSONDecoder().decode(ChatRequestTrace.self, from: JSONEncoder().encode(cancelled))
        check("nullable_trace_fields_roundtrip", restored == cancelled)
        var retryParser = ChatEventParser(requestID: runID.uuidString, model: model, fixtureOnly: false)
        for attempt in 1...3 {
            _ = try retryParser.consume(event(object(requestTraceFixture(runID: runID, attempt: attempt))))
            _ = try retryParser.consume(event(object(requestTraceFixture(runID: runID, attempt: attempt, phase: .response))))
        }
        check("three_attempts_are_separate_and_bounded", true)
    } catch { check("valid_snapshot_protocol", false) }

    rejects("unknown_trace_field_rejected") { $0["raw_error"] = "private provider error" }
    rejects("missing_nullable_field_rejected") { $0.removeValue(forKey: "duration_ms") }
    rejects("foreign_run_rejected") { $0["attempt_id"] = "\(UUID().uuidString):1" }
    rejects("nonsequential_attempt_rejected") { $0["attempt"] = 2; $0["attempt_id"] = "\(runID.uuidString):2" }
    rejects("fourth_attempt_rejected") { $0["attempt"] = 4; $0["attempt_id"] = "\(runID.uuidString):4" }
    rejects("dangerous_authorization_header_rejected") { $0["headers"] = ["authorization": "Bearer private"] }
    rejects("dangerous_api_key_header_rejected") { $0["headers"] = ["x-api-key": "private"] }
    rejects("unknown_diagnostic_header_rejected") { $0["headers"] = ["x-stainless-runtime": "private"] }
    rejects("header_control_character_rejected") { $0["headers"] = ["content-type": "application/json\r\nAuthorization: private"] }
    rejects("oversize_header_rejected") { $0["headers"] = ["user-agent": String(repeating: "x", count: 4_097)] }
    rejects("invalid_session_id_rejected") { $0["headers"] = ["x-claude-code-session-id": "private-token"] }
    rejects("credential_url_rejected") { $0["url"] = "https://credential@api.deepseek.com/anthropic/v1/messages" }
    rejects("extra_url_query_rejected") { $0["url"] = "https://api.deepseek.com/anthropic/v1/messages?token=private" }
    rejects("provider_mismatch_rejected") { $0["provider"] = "claude-subscription"; $0["url"] = "https://api.anthropic.com/v1/messages?beta=true" }
    rejects("direct_proxy_mode_rejected") { $0["proxy"] = ["mode": "direct", "url": NSNull()] }
    rejects("credential_proxy_url_rejected") { $0["proxy"] = ["mode": "http-connect", "url": "http://user:pass@127.0.0.1:7897"] }
    rejects("unknown_proxy_field_rejected") { $0["proxy"] = ["mode": "http-connect", "url": "http://127.0.0.1:7897", "raw_error": "private"] }
    rejects("truncated_body_rejected") { $0["body_truncated"] = true }
    rejects("invalid_json_body_rejected") { $0["body"] = "{\"model\":"; $0["body_bytes"] = 9 }
    rejects("body_wire_model_mismatch_rejected") { $0["wire_model"] = "other" }
    rejects("oversize_actual_body_rejected") { $0["body"] = String(repeating: "x", count: ChatRequestTrace.maximumBodyBytes + 1); $0["body_bytes"] = ChatRequestTrace.maximumBodyBytes + 1 }
    rejects("known_secret_inside_body_rejected", knownSecrets: ["offline-known-secret"]) {
        let body = "{\"model\":\"deepseek-flash[1m]\",\"messages\":[{\"content\":\"offline-known-secret\"}]}"
        $0["body"] = body; $0["body_bytes"] = body.utf8.count
    }
    rejects("json_escaped_known_secret_rejected", knownSecrets: ["credential-\"quote\\path"]) {
        let body = "{\"model\":\"deepseek-flash[1m]\",\"metadata\":{\"value\":\"credential-\\\"quote\\\\path\"}}"
        $0["body"] = body; $0["body_bytes"] = body.utf8.count
    }
    rejects("known_secret_in_safe_header_rejected", knownSecrets: ["offline-known-secret"]) { $0["headers"] = ["user-agent": "offline-known-secret"] }
    rejects("request_cannot_fabricate_http_response") { $0["status"] = 200 }
    rejects("boolean_status_rejected") { $0["status"] = true }
    rejects("terminal_without_request_rejected") { $0["phase"] = "response"; $0["status"] = 200; $0["duration_ms"] = 10; $0["outcome"] = "http" }
    rejects("raw_error_code_rejected") { $0["phase"] = "error"; $0["duration_ms"] = 10; $0["outcome"] = "network_error"; $0["error_code"] = "private response error" }
    rejects("negative_elapsed_rejected") { $0["duration_ms"] = -1 }
    do {
        let secret = "offline-known-secret"
        let body = "{\"model\":\"deepseek-flash[1m]\",\"metadata\":{\"value\":\"[REDACTED]\"}}"
        let safe = requestTraceFixture(runID: runID, body: body, bodyBytes: body.utf8.count + 10, secretsRedacted: true)
        try safe.validate(runID: runID, knownSecrets: [secret])
        check("redacted_json_keeps_actual_original_byte_count", safe.bodyBytes != safe.body.utf8.count && safe.secretsRedacted)
        var parser = ChatEventParser(requestID: runID.uuidString, model: model, fixtureOnly: false)
        _ = try parser.consume(event(object(trace)))
        var changed = try object(requestTraceFixture(runID: runID, phase: .response))
        changed["headers"] = ["content-type": "different"]
        do { _ = try parser.consume(event(changed)); check("terminal_cannot_replace_actual_request", false) }
        catch { check("terminal_cannot_replace_actual_request", true) }
    } catch { check("redacted_snapshot_and_request_identity", false) }
    return checks
}

func requestTraceFixture(runID: UUID, attempt: Int = 1, phase: ChatRequestTracePhase = .request,
                         provider: ExecutionProvider = .deepseekAPI, body: String? = nil,
                         bodyBytes: Int? = nil, secretsRedacted: Bool = false) -> ChatRequestTrace {
    let wireModel = provider == .deepseekAPI ? "deepseek-flash[1m]" : "claude-sonnet-4-6"
    let content = body ?? "{\n  \"model\": \"\(wireModel)\", \"messages\": [{\"role\": \"user\", \"content\": \"你好 🌏\"}], \"system\": \"CLI instructions\", \"metadata\": {\"session_id\": \"offline-fixture\"}\n}"
    return .init(attemptID: "\(runID.uuidString):\(attempt)", attempt: attempt, phase: phase, provider: provider,
                 url: provider == .deepseekAPI ? "https://api.deepseek.com/anthropic/v1/messages" : "https://api.anthropic.com/v1/messages?beta=true",
                 wireModel: wireModel, headers: ["content-type": "application/json", "anthropic-version": "2023-06-01"],
                 proxy: .init(url: "http://127.0.0.1:7897"), body: content, bodyBytes: bodyBytes ?? content.utf8.count,
                 secretsRedacted: secretsRedacted, status: phase == .response ? 200 : nil,
                 durationMS: phase == .request ? nil : 123.5, outcome: phase == .request ? nil : (phase == .response ? "http" : "network_error"),
                 errorCode: phase == .error ? "PROVIDER_NETWORK_ERROR" : nil)
}
