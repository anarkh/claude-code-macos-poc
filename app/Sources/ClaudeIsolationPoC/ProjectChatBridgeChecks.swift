import Foundation

/// Synthetic protocol checks; an execution grant must come from the request.
func projectChatBridgeChecks() -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { checks.append(("project_chat_" + name, passed)) }
    let runID = UUID(), model = "deepseek-flash[1m]", answer = "Project fixture complete."
    let base: [String: Any] = ["schema": "deepseek-text-chat-event/v1", "request_id": runID.uuidString,
                               "model": model, "fixture_only": false]
    func event(_ type: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var value = base
        value["type"] = type
        value.merge(fields) { _, replacement in replacement }
        return value
    }
    func started(project: Bool = true) -> [String: Any] { event("started", ["no_tools": !project]) }
    func tool(_ id: String, _ name: String = "Read", _ phase: String = "started") -> [String: Any] {
        event("tool_activity", ["tool_id": id, "tool": name, "phase": phase])
    }
    func completed(project: Bool = true, requests: Int = 1) -> [String: Any] {
        event("completed", ["text": answer, "no_tools": !project, "cli_exit": 0, "cli_signal": NSNull(),
                            "temporary_removed": true, "proxy_closed": true, "request_count": requests])
    }
    let delta = event("delta", ["text": answer])
    func rejects(_ name: String, project: Bool = true, _ values: [[String: Any]]) {
        var parser = ChatEventParser(requestID: runID.uuidString, model: model, fixtureOnly: false,
                                     projectExecution: project)
        do {
            for value in values { _ = try parser.consume(JSONSerialization.data(withJSONObject: value)) }
            check(name, false)
        } catch let failure as ChatFailure {
            if case .code(let code) = failure { check(name, code == "CHAT_RESPONSE_INVALID") }
        } catch { check(name, false) }
    }
    func traceEvent(attempt: Int, phase: ChatRequestTracePhase) throws -> [String: Any] {
        let trace = requestTraceFixture(runID: runID, attempt: attempt, phase: phase)
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trace))
        return event("request_trace", ["trace": value])
    }

    let request = ChatRequest(request_id: runID.uuidString, apiKey: "offline-project-fixture-key", model: model,
                              messages: [.init(role: "user", text: "Inspect this project.")])
    do {
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        check("text_request_has_no_implicit_project_grant", plain?["project"] == nil)
        var granted = request
        granted.project = .init(directory: "/offline/project with spaces/项目")
        try granted.validate()
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(granted)) as? [String: Any]
        let project = encoded?["project"] as? [String: Any]
        check("explicit_project_grant_encodes_only_selected_directory", Set(project?.keys.map { $0 } ?? []) == ["directory"] &&
              project?["directory"] as? String == granted.project?.directory)
    } catch { check("request_encoding", false) }
    for (name, path) in [("relative", "project"), ("empty", ""), ("root", "/"),
                         ("parent_component", "/tmp/project/../other"), ("repeated_separator", "/tmp//project"),
                         ("nul", "/tmp/project\0other")] {
        var invalid = request
        invalid.project = .init(directory: path)
        do { try invalid.validate(); check("rejects_" + name + "_directory", false) }
        catch let failure as ChatFailure {
            if case .code(let code) = failure { check("rejects_" + name + "_directory", code == "INVALID_PROJECT_DIRECTORY") }
        } catch { check("rejects_" + name + "_directory", false) }
    }

    rejects("text_request_cannot_enable_tools_in_started", project: false, [started()])
    rejects("text_request_rejects_tool_events", project: false, [started(project: false), tool("ungranted")])
    rejects("text_request_cannot_enable_tools_in_completion", project: false,
            [started(project: false), delta, completed()])
    rejects("project_request_cannot_silently_become_text_only", [started(project: false)])
    rejects("tool_activity_requires_started_request", [tool("before-start")])
    rejects("tool_completion_requires_matching_start", [started(), tool("unknown", "Read", "completed")])
    rejects("tool_cannot_change_name_mid_call", [started(), tool("read-1"), tool("read-1", "Write", "completed")])
    rejects("tool_id_cannot_be_started_twice", [started(), tool("read-1"), tool("read-1")])
    rejects("completed_tool_id_cannot_be_reused", [started(), tool("read-1"), tool("read-1", "Read", "completed"), tool("read-1")])
    rejects("terminal_tool_event_cannot_be_replayed", [started(), tool("read-1"),
            tool("read-1", "Read", "failed"), tool("read-1", "Read", "completed")])
    rejects("unfinished_tool_prevents_successful_completion", [started(), tool("read-1"), delta, completed()])
    rejects("unknown_tools_are_rejected", [started(), tool("external", "WebFetch")])
    rejects("unsafe_tool_id_is_rejected", [started(), tool("tool\nprivate")])
    var rawTool = tool("read-1")
    rawTool["input"] = ["path": "/private/unselected"]
    rejects("raw_tool_arguments_are_not_exposed_as_activity", [started(), rawTool])

    do {
        var parser = ChatEventParser(requestID: runID.uuidString, model: model, fixtureOnly: false, projectExecution: true)
        _ = try parser.consume(JSONSerialization.data(withJSONObject: started()))
        var delivered = true
        for (index, name) in ["Read", "Write", "Edit", "Bash", "Glob", "Grep"].enumerated() {
            let id = "tool-\(index)", phase = name == "Grep" ? "failed" : "completed"
            let start = try parser.consume(JSONSerialization.data(withJSONObject: tool(id, name)))
            let end = try parser.consume(JSONSerialization.data(withJSONObject: tool(id, name, phase)))
            delivered = delivered && start == .toolActivity(tool: name, phase: "started", toolID: id) &&
                end == .toolActivity(tool: name, phase: phase, toolID: id)
        }
        _ = try parser.consume(JSONSerialization.data(withJSONObject: delta))
        let receipt = try parser.consume(JSONSerialization.data(withJSONObject: completed()))
        let terminal = try parser.finish(processSucceeded: true)
        check("allowed_tools_report_lifecycle_and_failed_tool_is_terminal", delivered && receipt == nil &&
              terminal == .completed(answer))
        do { _ = try parser.finish(processSucceeded: false); check("project_completion_requires_successful_process_exit", false) }
        catch { check("project_completion_requires_successful_process_exit", true) }
    } catch { check("valid_project_tool_sequence", false) }

    do {
        var projectEvents = [started()]
        for attempt in 1...24 {
            projectEvents.append(try traceEvent(attempt: attempt, phase: .request))
            projectEvents.append(try traceEvent(attempt: attempt, phase: .response))
        }
        var parser = ChatEventParser(requestID: runID.uuidString, model: model, fixtureOnly: false, projectExecution: true)
        for value in projectEvents + [delta, completed(requests: 24)] {
            _ = try parser.consume(JSONSerialization.data(withJSONObject: value))
        }
        check("project_supports_24_completed_model_requests", try parser.finish(processSucceeded: true) == .completed(answer))
        rejects("project_rejects_25th_model_request", projectEvents + [try traceEvent(attempt: 25, phase: .request)])
        rejects("project_rejects_request_count_above_limit", [started(), delta, completed(requests: 25)])
        rejects("project_completion_requires_all_traces_terminal", [started(), try traceEvent(attempt: 1, phase: .request), delta, completed()])

        var textEvents = [started(project: false)]
        for attempt in 1...3 {
            textEvents.append(try traceEvent(attempt: attempt, phase: .request))
            textEvents.append(try traceEvent(attempt: attempt, phase: .response))
        }
        var textParser = ChatEventParser(requestID: runID.uuidString, model: model, fixtureOnly: false)
        for value in textEvents + [delta, completed(project: false, requests: 3)] {
            _ = try textParser.consume(JSONSerialization.data(withJSONObject: value))
        }
        check("text_path_still_accepts_three_requests_without_tools", try textParser.finish(processSucceeded: true) == .completed(answer))
        rejects("text_path_still_rejects_fourth_trace", project: false,
                textEvents + [try traceEvent(attempt: 4, phase: .request)])
        rejects("text_path_still_rejects_four_request_receipt", project: false,
                [started(project: false), delta, completed(project: false, requests: 4)])
    } catch { check("request_limit_fixtures", false) }

    for code in ["VM_PROJECT_UNSUPPORTED", "PROJECT_EXECUTION_UNSUPPORTED", "INVALID_PROJECT_DIRECTORY",
                 "PROJECT_DIRECTORY_UNAVAILABLE", "PROJECT_DIRECTORY_CHANGED", "PROJECT_DIRECTORY_PROTECTED",
                 "PROJECT_MOUNT_REJECTED", "PROJECT_MOUNT_UNAVAILABLE", "PROJECT_TOOL_REJECTED",
                 "PROJECT_TOOL_CONTRACT", "PROJECT_PATH_REJECTED"] {
        var parser = ChatEventParser(requestID: runID.uuidString, model: model, fixtureOnly: false, projectExecution: true)
        do {
            _ = try parser.consume(JSONSerialization.data(withJSONObject: event("error", ["code": code])))
            check("actionable_error_" + code.lowercased(), false)
        } catch let failure as ChatFailure {
            if case .code(let received) = failure {
                check("actionable_error_" + code.lowercased(), received == code &&
                      (failure.message.contains("目录") || failure.message.contains("项目")) && failure.message.count > 20)
            }
        } catch { check("actionable_error_" + code.lowercased(), false) }
    }
    return checks
}

/// Real Swift stdin/NDJSON transport, with a deny-network fake VM broker only.
func projectStdioBridgeChecks(configuration: AppConfiguration) async -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { checks.append(("project_stdio_" + name, passed)) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-project-bridge-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sdk"), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let selected = root.appendingPathComponent("项目 with 'quotes' and $literal", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let projectPath = try ProjectDirectory.normalized(selected.path)
        let sandbox = root.appendingPathComponent("no-network.sb")
        try Data("(version 1)\n(allow default)\n(deny network*)\n".utf8).write(to: sandbox)
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let wrapper = root.appendingPathComponent("node-probe")
        let launch = "#!/bin/sh\nexec /usr/bin/sandbox-exec -f \(quoted(sandbox.path)) \(quoted(configuration.nodeExecutable)) \"$@\"\n"
        try Data(launch.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let broker = #"""
        // Offline fixture: no VM, native CLI, model or project files are accessed.
        import { appendFileSync } from 'node:fs';
        appendFileSync(new URL('./bridge-launches', import.meta.url), 'x');
        const chunks = [];
        for await (const chunk of process.stdin) chunks.push(chunk);
        const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        const base = {schema:'deepseek-text-chat-event/v1',request_id:input.request_id,
          model:input.model,fixture_only:false};
        const emit = event => process.stdout.write(JSON.stringify({...base,...event}) + '\n');
        const no_tools = input.project === undefined;
        emit({type:'started',no_tools});
        if (!no_tools) {
          emit({type:'tool_activity',tool_id:'read-fixture',tool:'Read',phase:'started'});
          emit({type:'tool_activity',tool_id:'read-fixture',tool:'Read',phase:'completed'});
        }
        const text = JSON.stringify({project:input.project ?? null,argv:process.argv.slice(2)});
        emit({type:'delta',text});
        emit({type:'completed',text,no_tools,cli_exit:0,cli_signal:null,
          temporary_removed:true,proxy_closed:true,request_count:1});
        """#
        try Data(broker.utf8).write(to: root.appendingPathComponent("sdk/vm-text-chat.mjs"))
        let provider = StdioChatProvider(configuration: .init(projectRoot: root.path, nodeExecutable: wrapper.path),
            fixtureOnly: false, networkPolicyProvider: FixedNetworkPolicyProvider(),
            runtimeProfileProvider: FixedRuntimeProfileProvider(), installationIdentityStore: FixtureInstallationIdentityStore())
        struct Echo: Decodable {
            struct Project: Decodable { let directory: String }
            let project: Project?
            let argv: [String]
        }
        func collect(_ request: ChatRequest) async throws -> (Echo, [ChatEvent]) {
            var events: [ChatEvent] = []
            for try await event in provider.events(for: request) {
                events.append(event)
                if case .completed(let text) = event {
                    return (try JSONDecoder().decode(Echo.self, from: Data(text.utf8)), events)
                }
            }
            throw ChatFailure.code("CHAT_RESPONSE_INVALID")
        }
        let projectRequest = ChatRequest(request_id: UUID().uuidString, apiKey: "offline-project-bridge-key",
            model: "deepseek-flash[1m]", messages: [.init(role: "user", text: "Inspect the selected fixture.")],
            project: .init(directory: projectPath))
        let (projectEcho, projectEvents) = try await collect(projectRequest)
        check("selected_directory_reaches_broker_only_in_stdin", projectEcho.project?.directory == projectPath &&
              !projectEcho.argv.contains(where: { $0.contains(projectPath) }))
        check("authorized_tool_lifecycle_reaches_ui", projectEvents.contains(.toolActivity(tool: "Read", phase: "started", toolID: "read-fixture")) &&
              projectEvents.contains(.toolActivity(tool: "Read", phase: "completed", toolID: "read-fixture")))
        let textRequest = ChatRequest(request_id: UUID().uuidString, apiKey: "offline-project-bridge-key",
            model: "deepseek-flash[1m]", messages: [.init(role: "user", text: "Text-only fixture.")])
        let (textEcho, textEvents) = try await collect(textRequest)
        check("text_request_has_no_project_or_tool_activity", textEcho.project == nil && !textEvents.contains(where: {
            if case .toolActivity = $0 { return true }
            return false
        }))
        let launches = root.appendingPathComponent("sdk/bridge-launches")
        let launchesBefore = try Data(contentsOf: launches)
        try FileManager.default.removeItem(at: selected)
        do { _ = try await collect(projectRequest); check("removed_directory_fails_before_broker_launch", false) }
        catch let failure as ChatFailure {
            if case .code(let code) = failure {
                check("removed_directory_fails_before_broker_launch", try code == "PROJECT_DIRECTORY_UNAVAILABLE" &&
                      Data(contentsOf: launches) == launchesBefore)
            }
        } catch { check("removed_directory_fails_before_broker_launch", false) }
        let other = root.appendingPathComponent("different-project", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: other)
        do { _ = try await collect(projectRequest); check("changed_directory_fails_before_broker_launch", false) }
        catch let failure as ChatFailure {
            if case .code(let code) = failure {
                check("changed_directory_fails_before_broker_launch", try code == "PROJECT_DIRECTORY_CHANGED" &&
                      Data(contentsOf: launches) == launchesBefore)
            }
        } catch { check("changed_directory_fails_before_broker_launch", false) }
    } catch { check("offline_fixture_setup_or_execution", false) }
    if FileManager.default.fileExists(atPath: root.path) {
        do {
            try FileManager.default.removeItem(at: root)
            check("temporary_state_cleanup", true)
        } catch { check("temporary_state_cleanup", false) }
    }
    return checks
}
