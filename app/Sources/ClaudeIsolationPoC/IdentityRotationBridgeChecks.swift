import Foundation

/// Exercises the real Swift request path with a deny-network Node echo broker.
/// All credentials, identity files, runtime profiles and network settings are fixtures.
func installationIdentityBridgeChecks(configuration: AppConfiguration) async -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { checks.append(("installation_identity_bridge_" + name, passed)) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-identity-bridge-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sdk"), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let profile = root.appendingPathComponent("no-network.sb")
        try Data("(version 1)\n(allow default)\n(deny network*)\n".utf8).write(to: profile)
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let wrapper = root.appendingPathComponent("node-probe")
        let launch = "#!/bin/sh\nexec /usr/bin/sandbox-exec -f \(quoted(profile.path)) \(quoted(configuration.nodeExecutable)) \"$@\"\n"
        try Data(launch.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let script = #"""
        // Owned, offline echo broker. No native CLI, VM or provider is invoked.
        const chunks = [];
        for await (const chunk of process.stdin) chunks.push(chunk);
        const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        const emit = event => process.stdout.write(JSON.stringify(event) + '\n');
        const base = {schema:'deepseek-text-chat-event/v1',request_id:input.request_id,
          model:input.model,fixture_only:false};
        const text = JSON.stringify({identity:input.identity,request_id:input.request_id});
        emit({...base,type:'started',no_tools:true});
        emit({...base,type:'delta',text});
        emit({...base,type:'completed',text,no_tools:true,cli_exit:0,cli_signal:null,
          temporary_removed:true,proxy_closed:true,request_count:1});
        """#
        try Data(script.utf8).write(to: root.appendingPathComponent("sdk/vm-text-chat.mjs"))
        let identityStore = FileInstallationIdentityStore(directoryURL: root.appendingPathComponent("identity"))
        let provider = StdioChatProvider(configuration: .init(projectRoot: root.path, nodeExecutable: wrapper.path),
            fixtureOnly: false, networkPolicyProvider: FixedNetworkPolicyProvider(),
            runtimeProfileProvider: FixedRuntimeProfileProvider(), installationIdentityStore: identityStore)
        struct Echo: Decodable {
            let identity: ClaudeRequestIdentity
            let request_id: String
        }
        func request(sessionID: UUID) -> ChatRequest {
            ChatRequest(request_id: UUID().uuidString.lowercased(), model: "sonnet",
                messages: [.init(role: "user", text: "Offline installation identity probe.")],
                provider: .claudeSubscription, subscriptionToken: "sk-ant-oat01-offline-identity-probe-NOT-VALID",
                conversationSessionID: sessionID)
        }
        func echoed(_ request: ChatRequest) async throws -> Echo {
            for try await event in provider.events(for: request) {
                if case .completed(let text) = event {
                    let echo = try JSONDecoder().decode(Echo.self, from: Data(text.utf8))
                    try echo.identity.validate()
                    return echo
                }
            }
            throw ChatFailure.code("CHAT_RESPONSE_INVALID")
        }
        let conversationA = UUID(), conversationB = UUID()
        let firstRequest = request(sessionID: conversationA)
        let first = try await echoed(firstRequest)
        check("first_request_creates_persisted_device", try identityStore.loadDeviceID() == first.identity.device_id)
        check("first_request_uses_conversation_session", first.identity.session_id == conversationA.uuidString.lowercased())

        let replacement = try identityStore.replaceDeviceID()
        let replacedData = try Data(contentsOf: identityStore.fileURL)
        let secondRequest = request(sessionID: conversationA)
        let second = try await echoed(secondRequest)
        check("same_provider_reads_replaced_device", replacement != first.identity.device_id && second.identity.device_id == replacement)
        check("rotation_preserves_existing_session", second.identity.session_id == first.identity.session_id)

        let thirdRequest = request(sessionID: conversationB)
        let third = try await echoed(thirdRequest)
        check("new_conversation_keeps_replaced_device", third.identity.device_id == replacement)
        check("new_conversation_changes_session", third.identity.session_id == conversationB.uuidString.lowercased() &&
              third.identity.session_id != second.identity.session_id)
        check("each_request_keeps_distinct_request_id", first.request_id == firstRequest.request_id &&
              second.request_id == secondRequest.request_id && third.request_id == thirdRequest.request_id &&
              Set([first.request_id, second.request_id, third.request_id]).count == 3)
        check("requests_do_not_rewrite_replaced_identity", try Data(contentsOf: identityStore.fileURL) == replacedData)
    } catch { check("offline_rotation_flow", false) }
    if FileManager.default.fileExists(atPath: root.path) {
        do {
            try FileManager.default.removeItem(at: root)
            check("temporary_state_cleanup", true)
        } catch { check("temporary_state_cleanup", false) }
    }
    return checks
}
