import Foundation

enum ChatRequestTracePhase: String, Codable, Sendable {
    case request, response, error
}

struct ChatRequestTraceProxy: Codable, Equatable, Sendable {
    let mode: String
    let url: String?

    private enum CodingKeys: String, CodingKey, CaseIterable { case mode, url }

    init(mode: String = "http-connect", url: String?) { self.mode = mode; self.url = url }

    init(from decoder: any Decoder) throws {
        try checkTraceFields(decoder, expected: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decode(String.self, forKey: .mode)
        url = try values.decodeIfPresent(String.self, forKey: .url)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mode, forKey: .mode)
        try values.encode(url, forKey: .url)
    }

    func validate() throws {
        guard mode == "http-connect", let url else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
        do { try AppNetworkPolicy(proxyURL: url).validate() }
        catch { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
    }
}

/// A bounded snapshot of the actual CLI request. Credentials never belong here.
/// Only its response fields may change during the lifetime of one attempt.
struct ChatRequestTrace: Codable, Identifiable, Equatable, Sendable {
    static let maximumBodyBytes = 2 * 1_024 * 1_024
    static let safeHeaders: Set<String> = ["content-type", "content-length", "anthropic-version", "anthropic-beta",
        "x-app", "user-agent", "x-claude-code-session-id", "anthropic-dangerous-direct-browser-access"]
    static let safeErrorCodes: Set<String> = ["PROVIDER_NETWORK_ERROR", "PROVIDER_TIMEOUT", "CHAT_CANCELLED", "PROVIDER_PROTOCOL_ERROR"]

    let schema: String
    let attemptID: String
    let attempt: Int
    let phase: ChatRequestTracePhase
    let provider: ExecutionProvider
    let url: String
    let method: String
    let wireModel: String
    let headers: [String: String]
    let proxy: ChatRequestTraceProxy
    let body: String
    let bodyBytes: Int
    let bodyTruncated: Bool
    let secretsRedacted: Bool
    let status: Int?
    let durationMS: Double?
    let outcome: String?
    let errorCode: String?

    var id: String { attemptID }

    init(schema: String = "claude-request-trace/v1", attemptID: String, attempt: Int,
         phase: ChatRequestTracePhase = .request, provider: ExecutionProvider = .deepseekAPI,
         url: String = "https://api.deepseek.com/anthropic/v1/messages", method: String = "POST",
         wireModel: String, headers: [String: String], proxy: ChatRequestTraceProxy,
         body: String, bodyBytes: Int, bodyTruncated: Bool = false, secretsRedacted: Bool = false,
         status: Int? = nil, durationMS: Double? = nil, outcome: String? = nil, errorCode: String? = nil) {
        self.schema = schema; self.attemptID = attemptID; self.attempt = attempt; self.phase = phase
        self.provider = provider; self.url = url; self.method = method; self.wireModel = wireModel
        self.headers = headers; self.proxy = proxy; self.body = body; self.bodyBytes = bodyBytes
        self.bodyTruncated = bodyTruncated; self.secretsRedacted = secretsRedacted
        self.status = status; self.durationMS = durationMS; self.outcome = outcome; self.errorCode = errorCode
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, attemptID = "attempt_id", attempt, phase, provider, url, method
        case wireModel = "wire_model", headers, proxy, body, bodyBytes = "body_bytes"
        case bodyTruncated = "body_truncated", secretsRedacted = "secrets_redacted", status
        case durationMS = "duration_ms", outcome, errorCode = "error_code"
    }

    init(from decoder: any Decoder) throws {
        try checkTraceFields(decoder, expected: CodingKeys.allCases.map(\.rawValue))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(String.self, forKey: .schema)
        attemptID = try values.decode(String.self, forKey: .attemptID)
        attempt = try values.decode(Int.self, forKey: .attempt)
        phase = try values.decode(ChatRequestTracePhase.self, forKey: .phase)
        provider = try values.decode(ExecutionProvider.self, forKey: .provider)
        url = try values.decode(String.self, forKey: .url)
        method = try values.decode(String.self, forKey: .method)
        wireModel = try values.decode(String.self, forKey: .wireModel)
        headers = try values.decode([String: String].self, forKey: .headers)
        proxy = try values.decode(ChatRequestTraceProxy.self, forKey: .proxy)
        body = try values.decode(String.self, forKey: .body)
        bodyBytes = try values.decode(Int.self, forKey: .bodyBytes)
        bodyTruncated = try values.decode(Bool.self, forKey: .bodyTruncated)
        secretsRedacted = try values.decode(Bool.self, forKey: .secretsRedacted)
        status = try values.decodeIfPresent(Int.self, forKey: .status)
        durationMS = try values.decodeIfPresent(Double.self, forKey: .durationMS)
        outcome = try values.decodeIfPresent(String.self, forKey: .outcome)
        errorCode = try values.decodeIfPresent(String.self, forKey: .errorCode)
        try validate()
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schema, forKey: .schema); try values.encode(attemptID, forKey: .attemptID)
        try values.encode(attempt, forKey: .attempt); try values.encode(phase, forKey: .phase)
        try values.encode(provider, forKey: .provider); try values.encode(url, forKey: .url)
        try values.encode(method, forKey: .method); try values.encode(wireModel, forKey: .wireModel)
        try values.encode(headers, forKey: .headers); try values.encode(proxy, forKey: .proxy)
        try values.encode(body, forKey: .body); try values.encode(bodyBytes, forKey: .bodyBytes)
        try values.encode(bodyTruncated, forKey: .bodyTruncated); try values.encode(secretsRedacted, forKey: .secretsRedacted)
        try values.encode(status, forKey: .status); try values.encode(durationMS, forKey: .durationMS)
        try values.encode(outcome, forKey: .outcome); try values.encode(errorCode, forKey: .errorCode)
    }

    func validate(runID: UUID? = nil, knownSecrets: [String] = []) throws {
        let fail = ChatFailure.code("CHAT_RESPONSE_INVALID")
        let parts = attemptID.split(separator: ":", omittingEmptySubsequences: false)
        guard schema == "claude-request-trace/v1", (1...3).contains(attempt), parts.count == 2,
              let traceRunID = UUID(uuidString: String(parts[0])), parts[1] == Substring(String(attempt)),
              runID.map({ $0 == traceRunID }) ?? true,
              method == "POST", url == (provider == .deepseekAPI ? "https://api.deepseek.com/anthropic/v1/messages" : "https://api.anthropic.com/v1/messages?beta=true"),
              !wireModel.isEmpty, wireModel.utf8.count <= 256, !traceHasControls(wireModel),
              !bodyTruncated, (1...Self.maximumBodyBytes).contains(bodyBytes),
              !body.isEmpty, body.utf8.count <= Self.maximumBodyBytes,
              secretsRedacted || bodyBytes == body.utf8.count,
              headers.count <= Self.safeHeaders.count,
              headers.allSatisfy({ Self.safeHeaders.contains($0.key) && $0.value.utf8.count <= 4_096 && !traceHasControls($0.value) }),
              headers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 16_384,
              status.map({ (100...599).contains($0) }) ?? true,
              durationMS.map({ $0.isFinite && $0 >= 0 && $0 <= 86_400_000 }) ?? true,
              let jsonBody = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              jsonBody["model"] as? String == wireModel
        else { throw fail }
        try proxy.validate()
        if let length = headers["content-length"] {
            guard length == String(bodyBytes) else { throw fail }
        }
        if let session = headers["x-claude-code-session-id"] {
            guard UUID(uuidString: session) != nil else { throw fail }
        }
        switch phase {
        case .request:
            guard status == nil, durationMS == nil, outcome == nil, errorCode == nil else { throw fail }
        case .response:
            guard status != nil, durationMS != nil, outcome == "http", errorCode == nil else { throw fail }
        case .error:
            guard let errorCode, Self.safeErrorCodes.contains(errorCode),
                  outcome == "network_error" || outcome == "cancelled",
                  (outcome == "cancelled") == (errorCode == "CHAT_CANCELLED"),
                  durationMS != nil || outcome == "cancelled" else { throw fail }
        }
        // Inspect decoded JSON strings as well as the wire text: a credential
        // copied into a message may have JSON escapes in the serialized body.
        var strings = [attemptID, url, wireModel, proxy.url ?? ""] + Array(headers.keys) + Array(headers.values)
        var pending: [Any] = [jsonBody]
        while let value = pending.popLast() {
            if let string = value as? String { strings.append(string) }
            else if let dictionary = value as? [String: Any] { strings.append(contentsOf: dictionary.keys); pending.append(contentsOf: dictionary.values) }
            else if let array = value as? [Any] { pending.append(contentsOf: array) }
        }
        guard !knownSecrets.filter({ !$0.isEmpty }).contains(where: { secret in strings.contains(where: { $0.contains(secret) }) }) else { throw fail }
    }

    func hasSameRequest(as other: Self) -> Bool {
        schema == other.schema && attemptID == other.attemptID && attempt == other.attempt && provider == other.provider &&
        url == other.url && method == other.method && wireModel == other.wireModel && headers == other.headers &&
        proxy == other.proxy && body == other.body && bodyBytes == other.bodyBytes &&
        bodyTruncated == other.bodyTruncated && secretsRedacted == other.secretsRedacted
    }

    /// App cancellation or a restart can interrupt event delivery before the
    /// transport reports elapsed time. Nil keeps that unknown duration honest.
    func markingInterrupted() -> Self {
        guard phase == .request else { return self }
        return .init(schema: schema, attemptID: attemptID, attempt: attempt, phase: .error, provider: provider,
                     url: url, method: method, wireModel: wireModel, headers: headers, proxy: proxy,
                     body: body, bodyBytes: bodyBytes, bodyTruncated: bodyTruncated, secretsRedacted: secretsRedacted,
                     outcome: "cancelled", errorCode: "CHAT_CANCELLED")
    }
}

private func traceHasControls(_ value: String) -> Bool {
    value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }
}

private struct TraceCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func checkTraceFields(_ decoder: any Decoder, expected: [String]) throws {
    let fields = try decoder.container(keyedBy: TraceCodingKey.self)
    guard Set(fields.allKeys.map(\.stringValue)) == Set(expected) else { throw ChatFailure.code("CHAT_RESPONSE_INVALID") }
}
