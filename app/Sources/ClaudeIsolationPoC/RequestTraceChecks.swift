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
    checks.append(contentsOf: requestTracePrivacyChecks())
    return checks
}

private func requestTracePrivacyChecks() -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { checks.append(("request_trace_privacy_" + name, passed)) }
    let runID = UUID()
    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let retainedMessage = "synthetic-body-marker-keep-only-with-explicit-capture"
    let sensitiveMarkers = ["synthetic-device-identity", "synthetic-session-identity", "synthetic-account-identity",
                            "synthetic-api-key", "synthetic-access-token", "synthetic-refresh-token", "synthetic-authorization",
                            "synthetic-embedded-identity", "sk-ant-oat01-syntheticRecognizableToken12345"]
    let sessionHeader = UUID().uuidString
    do {
        let bodyObject: [String: Any] = [
            "model": "deepseek-flash[1m]",
            "messages": [["role": "user", "content": retainedMessage]],
            "metadata": ["device_id": sensitiveMarkers[0], "session_id": sensitiveMarkers[1], "user_id": sensitiveMarkers[2]],
            "api_key": sensitiveMarkers[3],
            "nested": ["access_token": sensitiveMarkers[4], "refresh_token": sensitiveMarkers[5], "authorization": sensitiveMarkers[6]],
            "encoded": "{\"session_id\":\"\(sensitiveMarkers[7])\"}",
            "free_text": "Synthetic token \(sensitiveMarkers[8])"
        ]
        let body = String(decoding: try JSONSerialization.data(withJSONObject: bodyObject, options: [.sortedKeys]), as: UTF8.self)
        let fixture = requestTraceFixture(runID: runID, phase: .response, body: body)
        var wireObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as! [String: Any]
        var headers = wireObject["headers"] as! [String: String]
        headers["x-claude-code-session-id"] = sessionHeader
        wireObject["headers"] = headers
        let originalBytes = try JSONSerialization.data(withJSONObject: wireObject, options: [.sortedKeys])
        let wire = try JSONDecoder().decode(ChatRequestTrace.self, from: originalBytes)
        let summary = wire.persisted(captureBody: false, capturedAt: capturedAt)
        let full = wire.persisted(captureBody: true, capturedAt: capturedAt)
        try summary.validate(runID: runID)
        try full.validate(runID: runID)
        check("default_projection_omits_body", summary.schema == "claude-request-trace/v2" && summary.bodyAvailability == .notCaptured && !summary.hasBody && summary.body.isEmpty)
        let summaryBytes = try JSONEncoder().encode(summary)
        let encodedSummary = String(decoding: summaryBytes, as: UTF8.self)
        check("default_projection_never_serializes_sensitive_body_markers", !encodedSummary.contains(retainedMessage) && sensitiveMarkers.allSatisfy { !encodedSummary.contains($0) })
        check("projection_removes_session_header", summary.headers["x-claude-code-session-id"] == nil && full.headers["x-claude-code-session-id"] == nil)
        check("summary_preserves_request_metadata", summary.bodyBytes == wire.bodyBytes && summary.attemptID == wire.attemptID && summary.phase == wire.phase && summary.status == wire.status && summary.durationMS == wire.durationMS)
        check("explicit_capture_retains_exact_body_for_24_hours", full.bodyAvailability == .available && full.hasBody && full.body == body && full.capturedAt == capturedAt && full.expiresAt == capturedAt.addingTimeInterval(86_400))
        check("capture_before_deadline_unchanged", full.removingExpiredBody(now: capturedAt.addingTimeInterval(86_399.999)) == full)
        let expired = full.removingExpiredBody(now: capturedAt.addingTimeInterval(86_400))
        try expired.validate(runID: runID)
        check("capture_expires_at_exact_deadline", expired.bodyAvailability == .expired && !expired.hasBody && expired.body.isEmpty && expired.bodyBytes == wire.bodyBytes)
        check("expiry_preserves_diagnostic_metadata", expired.attemptID == full.attemptID && expired.status == full.status && expired.phase == full.phase && expired.durationMS == full.durationMS && expired.capturedAt == full.capturedAt && expired.expiresAt == full.expiresAt)
        check("summary_and_expired_projection_are_idempotent", summary.removingExpiredBody(now: capturedAt.addingTimeInterval(172_800)) == summary && expired.removingExpiredBody(now: capturedAt.addingTimeInterval(172_800)) == expired)
        check("legacy_has_no_inferred_expiry", wire.bodyAvailability == .legacy && wire.hasBody && wire.capturedAt == nil && wire.expiresAt == nil && wire.removingExpiredBody(now: capturedAt.addingTimeInterval(100 * 86_400)) == wire)
        let removedLegacy = wire.removingBody()
        let removedFull = full.removingBody()
        try removedLegacy.validate(runID: runID)
        try removedFull.validate(runID: runID)
        check("manual_removal_covers_legacy_and_new_bodies", [removedLegacy, removedFull].allSatisfy { $0.bodyAvailability == .removed && !$0.hasBody && $0.body.isEmpty && $0.bodyBytes == wire.bodyBytes && $0.status == wire.status && $0.attemptID == wire.attemptID })
        check("manual_removal_drops_legacy_session_header", removedLegacy.headers["x-claude-code-session-id"] == nil)
        check("new_states_roundtrip", try [summary, full, expired, removedLegacy, removedFull].allSatisfy { try JSONDecoder().decode(ChatRequestTrace.self, from: JSONEncoder().encode($0)) == $0 })

        let summaryExport = try full.diagnosticExport(now: capturedAt)
        let bodyExport = try full.diagnosticExport(includeBody: true, now: capturedAt)
        let expiredExport = try full.diagnosticExport(includeBody: true, now: capturedAt.addingTimeInterval(86_400))
        check("export_defaults_to_summary", !summaryExport.contains(retainedMessage) && sensitiveMarkers.allSatisfy { !summaryExport.contains($0) })
        check("explicit_export_removes_identity_and_secret_fields", bodyExport.contains(retainedMessage) && sensitiveMarkers.allSatisfy { !bodyExport.contains($0) } && !bodyExport.contains(sessionHeader))
        check("export_enforces_expiry_before_preview", !expiredExport.contains(retainedMessage) && sensitiveMarkers.allSatisfy { !expiredExport.contains($0) })
        check("export_produces_valid_json", [summaryExport, bodyExport, expiredExport].allSatisfy { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil })
        let originalWire = try JSONDecoder().decode(ChatRequestTrace.self, from: originalBytes)
        check("projection_and_export_leave_outbound_wire_unchanged", wire.schema == "claude-request-trace/v1" && wire.body == body && wire.headers["x-claude-code-session-id"] == sessionHeader && originalWire == wire)

        func rejectsStored(_ name: String, mutate: (inout [String: Any]) -> Void) throws {
            var value = try JSONSerialization.jsonObject(with: summaryBytes) as! [String: Any]
            mutate(&value)
            do {
                _ = try JSONDecoder().decode(ChatRequestTrace.self, from: JSONSerialization.data(withJSONObject: value))
                check(name, false)
            } catch { check(name, true) }
        }
        try rejectsStored("unknown_storage_field_rejected") { $0["private_raw_error"] = "synthetic-error" }
        try rejectsStored("missing_body_state_rejected") { $0.removeValue(forKey: "body_state") }
        try rejectsStored("missing_nullable_expiry_rejected") { $0.removeValue(forKey: "expires_at") }
        try rejectsStored("summary_cannot_hide_nonempty_body") { $0["body"] = body }
        try rejectsStored("summary_cannot_reintroduce_session_header") { $0["headers"] = ["x-claude-code-session-id": UUID().uuidString] }
        try rejectsStored("unknown_body_state_rejected") { $0["body_state"] = "hidden" }
        try rejectsStored("summary_cannot_claim_capture_dates") { $0["captured_at"] = capturedAt.timeIntervalSince1970 }
        try rejectsStored("captured_body_requires_both_dates") { $0["body_state"] = "captured"; $0["body"] = body }
        try rejectsStored("retention_cannot_extend_beyond_24_hours") {
            $0["body_state"] = "captured"; $0["body"] = body
            $0["captured_at"] = capturedAt.timeIntervalSince1970
            $0["expires_at"] = capturedAt.addingTimeInterval(86_401).timeIntervalSince1970
        }
        try rejectsStored("unsupported_trace_schema_rejected") { $0["schema"] = "claude-request-trace/v3" }
    } catch { check("setup_or_operation_failure", false) }
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
