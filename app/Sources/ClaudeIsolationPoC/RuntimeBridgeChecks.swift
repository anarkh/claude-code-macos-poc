import Foundation

/// The three real Swift launchers run an owned Node probe under deny-network.
/// Protocol responses are fixtures; no native CLI or provider is invoked here.
func runtimeBridgeChecks(configuration: AppConfiguration) async -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-runtime-bridge-\(UUID().uuidString)")
    let key = "runtime-offline-probe-key-NOT-VALID"
    let network = FixedNetworkPolicyProvider()
    let translationRequest = TranslationRequest(request_id: "runtime-probe", operation: "translate_input", text: "运行环境检查。",
        target: "en", model: .init(endpoint: "https://api.deepseek.com", model: "deepseek-flash", apiKey: key))
    let chatRequest = ChatRequest(request_id: UUID().uuidString.lowercased(), apiKey: key, model: "deepseek-flash[1m]",
        messages: [.init(role: "user", text: "Runtime probe.")])
    do {
        for folder in ["sdk", "translation"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let profilePath = root.appendingPathComponent("no-network.sb")
        try Data("(version 1)\n(allow default)\n(deny network*)\n".utf8).write(to: profilePath)
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let wrapper = root.appendingPathComponent("node-probe")
        let launch = "#!/bin/sh\nexec /usr/bin/sandbox-exec -f \(quoted(profilePath.path)) \(quoted(configuration.nodeExecutable)) \"$@\"\n"
        try Data(launch.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let common = #"""
        // Owned, offline launcher fixture. Never sends a provider request.
        import { createHash } from 'node:crypto';
        const chunks = [];
        for await (const chunk of process.stdin) chunks.push(chunk);
        const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        const p = input.runtime;
        const locales = {ja: 'ja_JP.UTF-8', en: 'en_US.UTF-8', zh: 'zh_CN.UTF-8'};
        const intlLocales = {ja: 'ja-JP', en: 'en-US', zh: 'zh-CN'};
        const resolved = new Intl.DateTimeFormat().resolvedOptions();
        const ok = p?.schema === 'app-runtime-profile/v1' &&
          process.env.TZ === p.timeZone && process.env.LANG === locales[p.language] &&
          process.env.LC_ALL === locales[p.language] && process.env.LC_MESSAGES === locales[p.language] &&
          resolved.locale === intlLocales[p.language] && resolved.timeZone === p.timeZone &&
          new Date('2026-01-01T00:00:00Z').getTimezoneOffset() === (p.timeZone === 'UTC' ? 0 : -540);
        const emit = obj => process.stdout.write(JSON.stringify(obj) + '\n');
        """#
        let translationProbe = common + #"""

        if (!ok) { emit({ok:false,error_code:'RUNTIME_PROFILE_INVALID'}); process.exitCode=1; }
        else {
          const text = 'RUNTIME_PROFILE_OK';
          emit({ok:true,request_id:'runtime-probe',original:input.text,translated:text,revision:1,
            translation_sha256:createHash('sha256').update(text).digest('hex'),requires_confirmation:true,fixture_only:false});
        }
        """#
        let chatProbe = common + #"""

        const base = {schema:'deepseek-text-chat-event/v1',request_id:input.request_id,model:input.model,fixture_only:false};
        if (!ok) { emit({...base,type:'error',code:'RUNTIME_PROFILE_INVALID'}); process.exitCode=1; }
        else {
          emit({...base,type:'started',no_tools:true});
          emit({...base,type:'delta',text:'RUNTIME_PROFILE_OK'});
          emit({...base,type:'completed',text:'RUNTIME_PROFILE_OK',no_tools:true,cli_exit:0,cli_signal:null,
            temporary_removed:true,proxy_closed:true,request_count:1});
        }
        """#
        let connectionProbe = common + #"""

        emit({ok,code:ok?'OK':'RUNTIME_PROFILE_INVALID',model:input.model,ack:ok?'DEEPSEEK_CLI_OK':null,
          no_tools:true,request_count:1,cli:{exit_code:0,signal:null},cleanup:{temporary_removed:true,proxy_closed:true}});
        if (!ok) process.exitCode=1;
        """#
        for (path, script) in [("translation/stdio.mjs", translationProbe), ("sdk/vm-text-chat.mjs", chatProbe),
                               ("sdk/vm-text-smoke.mjs", connectionProbe)] {
            try Data(script.utf8).write(to: root.appendingPathComponent(path))
        }
        let probe = AppConfiguration(projectRoot: root.path, nodeExecutable: wrapper.path)
        for (name, profile) in [("japan", AppRuntimeProfile.japan),
                                ("tokyo_english", AppRuntimeProfile(timeZone: "Asia/Tokyo", language: "en")),
                                ("utc_chinese", AppRuntimeProfile(timeZone: "UTC", language: "zh"))] {
            let profiles = FixedRuntimeProfileProvider(profile: profile)
            do {
                let reply = try await StdioTranslationProvider(configuration: probe, networkPolicyProvider: network,
                    runtimeProfileProvider: profiles).translate(translationRequest)
                checks.append(("runtime_\(name)_translation_real_node_env_and_payload", reply.ok && reply.translated == "RUNTIME_PROFILE_OK"))
            } catch { checks.append(("runtime_\(name)_translation_real_node_env_and_payload", false)) }
            do {
                var completed = false
                for try await event in StdioChatProvider(configuration: probe, networkPolicyProvider: network,
                    runtimeProfileProvider: profiles).events(for: chatRequest) {
                    if case .completed(let text) = event { completed = text == "RUNTIME_PROFILE_OK" }
                }
                checks.append(("runtime_\(name)_chat_real_node_env_and_payload", completed))
            } catch { checks.append(("runtime_\(name)_chat_real_node_env_and_payload", false)) }
            do {
                let reply = try await StdioExecutionConnectionTester(configuration: probe, networkPolicyProvider: network,
                    runtimeProfileProvider: profiles).test(apiKey: key, model: "deepseek-flash[1m]")
                checks.append(("runtime_\(name)_connection_real_node_env_and_payload", reply.ok))
            } catch { checks.append(("runtime_\(name)_connection_real_node_env_and_payload", false)) }
        }
    } catch { checks.append(("runtime_bridge_fixture_setup", false)) }
    let unavailable = AppConfiguration(projectRoot: "/nonexistent-runtime-probe", nodeExecutable: "/nonexistent-runtime-node")
    let invalid = FixedRuntimeProfileProvider(profile: .init(timeZone: "Not/A-TimeZone", language: "ja"))
    do {
        _ = try await StdioTranslationProvider(configuration: unavailable, networkPolicyProvider: network,
            runtimeProfileProvider: invalid).translate(translationRequest)
        checks.append(("runtime_translation_invalid_profile_rejected_before_launch", false))
    } catch let failure as TranslationFailure {
        if case .code(let code) = failure { checks.append(("runtime_translation_invalid_profile_rejected_before_launch", code == "RUNTIME_PROFILE_INVALID")) }
    } catch { checks.append(("runtime_translation_invalid_profile_rejected_before_launch", false)) }
    do {
        for try await _ in StdioChatProvider(configuration: unavailable, networkPolicyProvider: network,
            runtimeProfileProvider: invalid).events(for: chatRequest) {}
        checks.append(("runtime_chat_invalid_profile_rejected_before_launch", false))
    } catch let failure as ChatFailure {
        if case .code(let code) = failure { checks.append(("runtime_chat_invalid_profile_rejected_before_launch", code == "RUNTIME_PROFILE_INVALID")) }
    } catch { checks.append(("runtime_chat_invalid_profile_rejected_before_launch", false)) }
    do {
        _ = try await StdioExecutionConnectionTester(configuration: unavailable, networkPolicyProvider: network,
            runtimeProfileProvider: invalid).test(apiKey: key, model: "deepseek-flash[1m]")
        checks.append(("runtime_connection_invalid_profile_rejected_before_launch", false))
    } catch let failure as ExecutionConnectionFailure {
        checks.append(("runtime_connection_invalid_profile_rejected_before_launch", failure.code == "RUNTIME_PROFILE_INVALID"))
    } catch { checks.append(("runtime_connection_invalid_profile_rejected_before_launch", false)) }
    checks.append(("runtime_all_bridges_show_settings_instruction",
        ChatFailure.code("RUNTIME_PROFILE_INVALID").message.contains("运行环境") &&
        TranslationFailure.code("RUNTIME_PROFILE_INVALID").message.contains("运行环境") &&
        ExecutionConnectionFailure(code: "RUNTIME_PROFILE_INVALID").message.contains("运行环境")))
    if FileManager.default.fileExists(atPath: root.path) {
        do {
            try FileManager.default.removeItem(at: root)
            checks.append(("runtime_bridge_fixture_cleanup", true))
        } catch { checks.append(("runtime_bridge_fixture_cleanup", false)) }
    }
    return checks
}
