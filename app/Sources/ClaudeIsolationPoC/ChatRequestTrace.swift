import Foundation

enum ChatRequestTracePhase: String, Codable, Sendable {
    case request, response, error
}

enum ChatRequestBodyAvailability: String, Sendable {
    case legacy, available, notCaptured, expired, removed
}

private enum PersistedTraceBodyState: String, Codable, Sendable {
    case captured, notCaptured = "not_captured", expired, removed
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

/// Version 1 is the unchanged runtime wire contract; version 2 is an App-owned
/// diagnostic record with an explicit body-retention policy.
struct ChatRequestTrace: Codable, Identifiable, Equatable, Sendable {
    static let maximumAttempts = 24
    static let maximumBodyBytes = 2 * 1_024 * 1_024
    static let bodyRetention: TimeInterval = 24 * 60 * 60
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
    private let bodyState: PersistedTraceBodyState?
    let capturedAt: Date?
    let expiresAt: Date?

    var id: String { attemptID }
    var bodyAvailability: ChatRequestBodyAvailability {
        guard let bodyState else { return .legacy }
        switch bodyState {
        case .captured: return .available
        case .notCaptured: return .notCaptured
        case .expired: return .expired
        case .removed: return .removed
        }
    }
    var hasBody: Bool { bodyAvailability == .legacy || bodyAvailability == .available }

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
        self.bodyState = nil; self.capturedAt = nil; self.expiresAt = nil
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, attemptID = "attempt_id", attempt, phase, provider, url, method
        case wireModel = "wire_model", headers, proxy, body, bodyBytes = "body_bytes"
        case bodyTruncated = "body_truncated", secretsRedacted = "secrets_redacted", status
        case durationMS = "duration_ms", outcome, errorCode = "error_code"
        case bodyState = "body_state", capturedAt = "captured_at", expiresAt = "expires_at"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchema = try values.decode(String.self, forKey: .schema)
        schema = decodedSchema
        let retentionFields: Set<CodingKeys> = [.bodyState, .capturedAt, .expiresAt]
        let fields = CodingKeys.allCases.filter { decodedSchema != "claude-request-trace/v1" || !retentionFields.contains($0) }
        try checkTraceFields(decoder, expected: fields.map(\.rawValue))
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
        bodyState = try values.decodeIfPresent(PersistedTraceBodyState.self, forKey: .bodyState)
        capturedAt = try values.decodeIfPresent(Double.self, forKey: .capturedAt).map(Date.init(timeIntervalSince1970:))
        expiresAt = try values.decodeIfPresent(Double.self, forKey: .expiresAt).map(Date.init(timeIntervalSince1970:))
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
        if schema == "claude-request-trace/v2" {
            try values.encode(bodyState, forKey: .bodyState)
            try values.encode(capturedAt?.timeIntervalSince1970, forKey: .capturedAt)
            try values.encode(expiresAt?.timeIntervalSince1970, forKey: .expiresAt)
        }
    }

    func validate(runID: UUID? = nil, knownSecrets: [String] = []) throws {
        let fail = ChatFailure.code("CHAT_RESPONSE_INVALID")
        let parts = attemptID.split(separator: ":", omittingEmptySubsequences: false)
        guard ["claude-request-trace/v1", "claude-request-trace/v2"].contains(schema), (1...Self.maximumAttempts).contains(attempt), parts.count == 2,
              let traceRunID = UUID(uuidString: String(parts[0])), parts[1] == Substring(String(attempt)),
              runID.map({ $0 == traceRunID }) ?? true,
              method == "POST", url == (provider == .deepseekAPI ? "https://api.deepseek.com/anthropic/v1/messages" : "https://api.anthropic.com/v1/messages?beta=true"),
              !wireModel.isEmpty, wireModel.utf8.count <= 256, !traceHasControls(wireModel),
              !bodyTruncated, (1...Self.maximumBodyBytes).contains(bodyBytes),
              body.utf8.count <= Self.maximumBodyBytes,
              headers.count <= Self.safeHeaders.count,
              headers.allSatisfy({ Self.safeHeaders.contains($0.key) && $0.value.utf8.count <= 4_096 && !traceHasControls($0.value) }),
              headers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 16_384,
              status.map({ (100...599).contains($0) }) ?? true,
              durationMS.map({ $0.isFinite && $0 >= 0 && $0 <= 86_400_000 }) ?? true
        else { throw fail }
        if schema == "claude-request-trace/v1" {
            guard bodyState == nil, capturedAt == nil, expiresAt == nil else { throw fail }
        } else {
            guard let bodyState, headers["x-claude-code-session-id"] == nil else { throw fail }
            switch bodyState {
            case .captured, .expired:
                guard let capturedAt, let expiresAt, capturedAt.timeIntervalSince1970.isFinite,
                      capturedAt.timeIntervalSince1970 >= 0, expiresAt.timeIntervalSince1970.isFinite,
                      abs(expiresAt.timeIntervalSince(capturedAt) - Self.bodyRetention) < 0.001 else { throw fail }
            case .notCaptured:
                guard capturedAt == nil, expiresAt == nil else { throw fail }
            case .removed:
                if let capturedAt, let expiresAt {
                    guard capturedAt.timeIntervalSince1970.isFinite, capturedAt.timeIntervalSince1970 >= 0,
                          expiresAt.timeIntervalSince1970.isFinite,
                          abs(expiresAt.timeIntervalSince(capturedAt) - Self.bodyRetention) < 0.001 else { throw fail }
                } else if capturedAt != nil || expiresAt != nil { throw fail }
            }
        }
        let jsonBody: [String: Any]
        if hasBody {
            guard !body.isEmpty, secretsRedacted || bodyBytes == body.utf8.count,
                  let decoded = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                  decoded["model"] as? String == wireModel else { throw fail }
            jsonBody = decoded
        } else {
            guard body.isEmpty else { throw fail }
            jsonBody = [:]
        }
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
        bodyTruncated == other.bodyTruncated && secretsRedacted == other.secretsRedacted &&
        bodyState == other.bodyState && capturedAt == other.capturedAt && expiresAt == other.expiresAt
    }

    /// App cancellation or a restart can interrupt event delivery before the
    /// transport reports elapsed time. Nil keeps that unknown duration honest.
    func markingInterrupted() -> Self {
        guard phase == .request else { return self }
        let interrupted = Self(schema: schema, attemptID: attemptID, attempt: attempt, phase: .error, provider: provider,
                     url: url, method: method, wireModel: wireModel, headers: headers, proxy: proxy,
                     body: body, bodyBytes: bodyBytes, bodyTruncated: bodyTruncated, secretsRedacted: secretsRedacted,
                     outcome: "cancelled", errorCode: "CHAT_CANCELLED")
        return interrupted.withRetention(bodyState, body: body, capturedAt: capturedAt, expiresAt: expiresAt)
    }

    /// Call only after the runtime event has passed its unchanged v1 validation.
    /// Terminal events must use the first event's capture time, not renew it.
    func persisted(captureBody: Bool, capturedAt: Date) -> Self {
        withRetention(captureBody ? .captured : .notCaptured, body: captureBody ? body : "",
                      capturedAt: captureBody ? capturedAt : nil,
                      expiresAt: captureBody ? capturedAt.addingTimeInterval(Self.bodyRetention) : nil)
    }

    func removingExpiredBody(now: Date) -> Self {
        guard bodyState == .captured, let expiresAt, now >= expiresAt else { return self }
        return withRetention(.expired, body: "", capturedAt: capturedAt, expiresAt: expiresAt)
    }

    func removingBody() -> Self {
        guard hasBody else { return self }
        return withRetention(.removed, body: "", capturedAt: capturedAt, expiresAt: expiresAt)
    }

    private init(copy source: Self, state: PersistedTraceBodyState?, body: String, capturedAt: Date?, expiresAt: Date?) {
        schema = state == nil ? source.schema : "claude-request-trace/v2"
        attemptID = source.attemptID; attempt = source.attempt; phase = source.phase; provider = source.provider
        url = source.url; method = source.method; wireModel = source.wireModel
        headers = state == nil ? source.headers : source.headers.filter { $0.key != "x-claude-code-session-id" }
        proxy = source.proxy; self.body = body; bodyBytes = source.bodyBytes
        bodyTruncated = source.bodyTruncated; secretsRedacted = source.secretsRedacted
        status = source.status; durationMS = source.durationMS; outcome = source.outcome; errorCode = source.errorCode
        bodyState = state; self.capturedAt = capturedAt; self.expiresAt = expiresAt
    }

    private func withRetention(_ state: PersistedTraceBodyState?, body: String, capturedAt: Date?, expiresAt: Date?) -> Self {
        Self(copy: self, state: state, body: body, capturedAt: capturedAt, expiresAt: expiresAt)
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
