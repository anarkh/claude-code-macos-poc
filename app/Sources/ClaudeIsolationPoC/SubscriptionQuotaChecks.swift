import Foundation

func subscriptionQuotaChecks() -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    let now = 1_793_073_600.0
    let window: [String: Any] = ["id": "five_hour", "usedPercentage": 25.5, "resetsAt": now + 3600]
    func success(_ windows: [[String: Any]], extra: [String: Any] = [:]) -> [String: Any] {
        ["schema": "claude-subscription-quota-response/v1", "ok": true, "windows": windows, "queriedAt": now]
            .merging(extra) { _, new in new }
    }
    func decode(_ object: [String: Any]) throws -> SubscriptionQuotaSnapshot {
        try StdioSubscriptionQuotaService.decodeResponse(JSONSerialization.data(withJSONObject: object))
    }
    func rejects(_ object: [String: Any], code: String = "QUOTA_RESPONSE_INVALID") -> Bool {
        do { _ = try decode(object); return false }
        catch let failure as SubscriptionQuotaFailure { return failure.code == code }
        catch { return false }
    }
    do {
        let snapshot = try decode(success([window]))
        checks.append(("quota_decodes_used_percentage_and_epoch_reset", snapshot.windows.first == .init(id: "five_hour", usedPercentage: 25.5,
            resetsAt: Date(timeIntervalSince1970: now + 3600)) && snapshot.queriedAt == Date(timeIntervalSince1970: now)))
        checks.append(("quota_remaining_percentage_is_derived_from_reported_usage", snapshot.windows.first?.remainingPercentage == 74.5))
        let empty = try decode(success([]))
        checks.append(("quota_absent_windows_are_not_zero_usage", empty.windows.isEmpty))
        let zero = try decode(success([["id": "seven_day", "usedPercentage": 0, "resetsAt": NSNull()]]))
        checks.append(("quota_explicit_zero_and_unknown_reset_are_preserved", zero.windows.first?.usedPercentage == 0 && zero.windows.first?.resetsAt == nil))
    } catch { checks.append(("quota_valid_reply_decoding", false)) }
    let expired = SubscriptionQuotaWindow(id: "five_hour", usedPercentage: 100, resetsAt: Date(timeIntervalSince1970: now))
    checks.append(("quota_reset_boundary_is_expired_without_fabricating_zero", expired.isExpired(at: Date(timeIntervalSince1970: now)) && expired.usedPercentage == 100))
    checks.append(("quota_before_reset_is_not_expired", !expired.isExpired(at: Date(timeIntervalSince1970: now - 1))))
    checks.append(("quota_unknown_reset_is_not_assumed_expired", !SubscriptionQuotaWindow(id: "five_hour", usedPercentage: 20, resetsAt: nil).isExpired(at: Date())))
    for (index, value) in [Any]([-1, 100.1, "25", true, NSNull()]).enumerated() {
        checks.append(("quota_invalid_percentage_\(index)_rejected", rejects(success([window.merging(["usedPercentage": value]) { _, value in value }]))))
    }
    for (index, changed) in [["resetsAt": -1], ["resetsAt": "tomorrow"], ["resetsAt": true], ["id": "untrusted"], ["secret": "must-not-display"]].enumerated() {
        checks.append(("quota_invalid_window_\(index)_rejected", rejects(success([window.merging(changed) { _, value in value }]))))
    }
    checks.append(("quota_duplicate_window_rejected", rejects(success([window, window]))))
    checks.append(("quota_unknown_top_level_fields_rejected", rejects(success([window], extra: ["raw": "must-not-display"]))))
    checks.append(("quota_missing_fields_rejected", rejects(["schema": "claude-subscription-quota-response/v1", "ok": true, "windows": [window]])))
    checks.append(("quota_future_schema_rejected", rejects(success([window], extra: ["schema": "claude-subscription-quota-response/v2"]))))
    checks.append(("quota_oversized_reply_rejected", {
        do { _ = try StdioSubscriptionQuotaService.decodeResponse(Data(repeating: 32, count: 65_537)); return false }
        catch let failure as SubscriptionQuotaFailure { return failure.code == "QUOTA_RESPONSE_INVALID" }
        catch { return false }
    }()))
    for code in ["QUOTA_UNAUTHORIZED", "QUOTA_FORBIDDEN", "QUOTA_RATE_LIMITED", "QUOTA_SERVICE_UNAVAILABLE", "PROXY_CONNECT_FAILED"] {
        checks.append(("quota_\(code.lowercased())_retained", rejects(["schema": "claude-subscription-quota-response/v1", "ok": false, "code": code], code: code)))
    }
    let secret = "sk-ant-oat01-SYNTHETIC-UNTRUSTED-ERROR"
    checks.append(("quota_untrusted_error_code_sanitized", rejects(["schema": "claude-subscription-quota-response/v1", "ok": false, "code": secret], code: "QUOTA_QUERY_FAILED")
        && !SubscriptionQuotaFailure(code: secret).message.contains(secret)))
    checks.append(("quota_permission_failure_explains_missing_scope", SubscriptionQuotaFailure(code: "QUOTA_FORBIDDEN").message.contains("没有额度查询权限")))
    checks.append(("quota_rate_limit_does_not_claim_exhaustion", SubscriptionQuotaFailure(code: "QUOTA_RATE_LIMITED").message.contains("不表示额度耗尽")))
    return checks
}

/// Exercises the actual App-to-Node boundary with synthetic fixtures only. No provider or VM is started.
func subscriptionQuotaBridgeChecks(configuration: AppConfiguration) async -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("subscription-quota-fixture-\(UUID().uuidString)")
    let script = root.appendingPathComponent("sdk/subscription-quota.mjs")
    let token = "sk-ant-oat01-SYNTHETIC-QUOTA-BRIDGE"
    let network = AppNetworkPolicy(proxyURL: "http://127.0.0.1:18765")
    let invalidRuntime = RuntimePackageStore(bundleContents: root.appendingPathComponent("not-an-installed-bundle"),
        storageRoot: root.appendingPathComponent("not-an-active-runtime"))
    let service = StdioSubscriptionQuotaService(configuration: AppConfiguration(projectRoot: root.path,
        nodeExecutable: configuration.nodeExecutable, runtimePackages: invalidRuntime), networkPolicyProvider: FixedNetworkPolicyProvider(policy: network))
    do {
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let readInput = """
        const chunks = [];
        for await (const chunk of process.stdin) chunks.push(chunk);
        const input = JSON.parse(Buffer.concat(chunks).toString());
        const emit = value => process.stdout.write(JSON.stringify(value) + '\\n');
        """
        func writeScript(_ body: String) throws {
            try Data((readInput + "\n" + body).utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
        }
        try writeScript("""
        const safe = input.schema === 'claude-subscription-quota-request/v1' &&
          input.subscriptionToken === '\(token)' && input.network.proxyURL === '\(network.proxyURL)' &&
          Object.keys(input).sort().join(',') === 'network,schema,subscriptionToken' &&
          !JSON.stringify(process.argv).includes(input.subscriptionToken) &&
          !JSON.stringify(process.env).includes(input.subscriptionToken);
        emit(safe ? {schema:'claude-subscription-quota-response/v1',ok:true,windows:[{id:'five_hour',usedPercentage:25,resetsAt:null}],queriedAt:1793073600}
          : {schema:'claude-subscription-quota-response/v1',ok:false,code:'QUOTA_INPUT_INVALID'});
        """)
        let result = try await service.fetch(token: token)
        checks.append(("quota_stdio_freezes_policy_and_keeps_token_off_argv_environment", result.windows.first?.usedPercentage == 25))
        checks.append(("quota_host_query_does_not_resolve_invalid_guest_runtime", result.windows.count == 1))
        try writeScript("emit({schema:'claude-subscription-quota-response/v1',ok:false,code:'QUOTA_FORBIDDEN'}); process.exitCode = 1;")
        do { _ = try await service.fetch(token: token); checks.append(("quota_stdio_permission_failure_keeps_reason", false)) }
        catch let failure as SubscriptionQuotaFailure { checks.append(("quota_stdio_permission_failure_keeps_reason", failure.code == "QUOTA_FORBIDDEN")) }
        catch { checks.append(("quota_stdio_permission_failure_keeps_reason", false)) }
        try writeScript("process.stdout.write('x'.repeat(70000));")
        do { _ = try await service.fetch(token: token); checks.append(("quota_stdio_bounds_reply", false)) }
        catch let failure as SubscriptionQuotaFailure { checks.append(("quota_stdio_bounds_reply", failure.code == "QUOTA_RESPONSE_INVALID")) }
        catch { checks.append(("quota_stdio_bounds_reply", false)) }
        try writeScript("setTimeout(() => {}, 20000);")
        let activeBefore = OwnedProcessRegistry.shared.activeCount
        let task = Task { try await service.fetch(token: token) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; checks.append(("quota_stdio_cancellation_stops_owned_process", false)) }
        catch is CancellationError { checks.append(("quota_stdio_cancellation_stops_owned_process", OwnedProcessRegistry.shared.activeCount == activeBefore)) }
        catch { checks.append(("quota_stdio_cancellation_stops_owned_process", false)) }
    } catch { checks.append(("quota_stdio_fixture_execution", false)) }
    do { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }
    catch { checks.append(("quota_stdio_fixture_cleanup", false)) }
    return checks
}
