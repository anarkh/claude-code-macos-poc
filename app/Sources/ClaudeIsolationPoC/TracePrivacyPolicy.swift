import Foundation

extension ChatRequestTrace {
    /// This is a separate, previewable diagnostic document, never a replayable
    /// provider request. It intentionally omits local and upstream identities.
    func diagnosticExport(includeBody: Bool = false, now: Date = Date()) throws -> String {
        try validate()
        guard now.timeIntervalSince1970.isFinite else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
        let trace = removingExpiredBody(now: now)
        var document: [String: Any] = [
            "schema": "claude-diagnostic-export/v1",
            "attempt": trace.attempt, "phase": trace.phase.rawValue,
            "provider": trace.provider.rawValue, "url": trace.url, "method": trace.method,
            "wire_model": trace.wireModel, "body_bytes": trace.bodyBytes,
            "body_availability": trace.bodyAvailability.rawValue,
            "body_included": includeBody && trace.hasBody,
            "headers": trace.headers.filter { $0.key != "x-claude-code-session-id" },
            "proxy_mode": trace.proxy.mode,
            "status": trace.status.map { $0 as Any } ?? NSNull(),
            "duration_ms": trace.durationMS.map { $0 as Any } ?? NSNull(),
            "outcome": trace.outcome.map { $0 as Any } ?? NSNull(),
            "error_code": trace.errorCode.map { $0 as Any } ?? NSNull(),
        ]
        if includeBody && trace.hasBody {
            let decoded = try JSONSerialization.jsonObject(with: Data(trace.body.utf8))
            document["body"] = DiagnosticRedaction.value(decoded)
            document["body_redaction"] = "Metadata, identity fields and recognizable credentials removed; review free text before sharing."
        }
        // Headers and other string fields are checked too, including legacy
        // records created before a current credential was known to the App.
        let cleaned = DiagnosticRedaction.value(document)
        let data = try JSONSerialization.data(withJSONObject: cleaned, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
        return text
    }
}

private enum DiagnosticRedaction {
    private static let sensitiveKeys: Set<String> = [
        "metadata", "authorization", "proxyauthorization", "cookie", "setcookie", "apikey", "xapikey",
        "token", "accesstoken", "refreshtoken", "idtoken", "password", "passphrase", "secret", "clientsecret",
        "privatekey", "credential", "credentials", "deviceid", "sessionid", "userid", "accountid",
        "organizationid", "installationid", "clientid", "xclaudecodesessionid",
    ]

    static func value(_ input: Any) -> Any {
        if let fields = input as? [String: Any] {
            return fields.reduce(into: [String: Any]()) { output, field in
                let normalized = field.key.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
                if sensitiveKeys.contains(normalized) || normalized.hasSuffix("password") || normalized.hasSuffix("secret") || normalized.hasSuffix("token") {
                    output[field.key] = "[REDACTED]"
                } else { output[field.key] = value(field.value) }
            }
        }
        if let values = input as? [Any] { return values.map(value) }
        if let text = input as? String { return redactedText(text) }
        return input
    }

    private static func redactedText(_ text: String) -> String {
        var output = text
        // Some CLI attribution fields contain JSON encoded inside a string.
        // Valid embedded JSON gets the same field policy; ordinary prose and
        // malformed JSON still pass through recognizable-token redaction.
        if let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first, first == "{" || first == "[" {
            do {
                let decoded = try JSONSerialization.jsonObject(with: Data(text.utf8))
                let data = try JSONSerialization.data(withJSONObject: value(decoded), options: [.sortedKeys, .withoutEscapingSlashes])
                if let encoded = String(data: data, encoding: .utf8) { output = encoded }
            } catch {
                // Free text is not required to be valid JSON; the literal
                // token rules below still apply to that original text.
                output = text
            }
        }
        output = output.replacingOccurrences(of: #"\bsk-(?:ant-(?:api\d+|oat\d+)-)?[A-Za-z0-9_-]{12,}"#, with: "[REDACTED]", options: .regularExpression)
        output = output.replacingOccurrences(of: #"(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*"#, with: "Bearer [REDACTED]", options: .regularExpression)
        output = output.replacingOccurrences(of: #"(?i)\b(authorization|api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|password|secret)(\s*[:=]\s*)(?:Bearer\s+)?[^\s,;]+"#, with: "$1$2[REDACTED]", options: .regularExpression)
        return output
    }
}
