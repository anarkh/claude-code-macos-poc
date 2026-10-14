import Darwin
import Foundation

/// Local read-only replay checks. Every synthetic evidence file stays under one owned
/// temporary directory; the actual project is read without invoking a model or CLI.
func executionReplayChecks(projectRoot: String) -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    let manager = FileManager.default
    let temporary = manager.temporaryDirectory.appendingPathComponent("claude-replay-checks-\(UUID().uuidString)", isDirectory: true)
    do {
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
    } catch {
        return [("replay_owned_temporary_directory_created", false)]
    }
    var directoryNumber = 0
    func directory() throws -> URL {
        directoryNumber += 1
        let root = temporary.appendingPathComponent("case-\(directoryNumber)", isDirectory: true)
        try manager.createDirectory(at: root.appendingPathComponent("host/evidence", isDirectory: true), withIntermediateDirectories: true)
        return root
    }
    func check(_ name: String, _ body: () throws -> Bool) {
        do { checks.append((name, try body())) }
        catch { checks.append((name, false)) }
    }
    func write(_ object: [String: Any], run: String, root: URL, suffix: String = "") throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: root.appendingPathComponent("host/evidence/\(run)\(suffix).json"))
    }
    func load(_ root: URL) -> ExecutionReplay { ExecutionReplay.load(projectRoot: root.path) }
    func tools(_ replay: ExecutionReplay) -> [ReplayEntry] { replay.entries.filter { $0.kind == .tool } }
    func displayed(_ replay: ExecutionReplay) -> String {
        ([replay.run, replay.notice] + replay.entries.flatMap { [$0.title, $0.subtitle, $0.parameters ?? "", $0.output ?? "", $0.approval ?? ""] }).joined(separator: "\n")
    }
    func assistant(_ content: [[String: Any]]) -> [String: Any] { ["type": "assistant", "message": ["content": content]] }
    func tool(_ name: String, _ id: String, _ input: [String: Any] = [:]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }
    func result(_ id: String, _ output: Any, error: Bool? = nil) -> [String: Any] {
        var content: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": output]
        if let error { content["is_error"] = error }
        return ["type": "user", "message": ["content": [content]]]
    }
    func permission(_ name: String, _ id: String, input: [String: Any] = [:], fixture: Bool = true, behavior: String = "allow") -> [String: Any] {
        ["fixture_only": fixture, "name": name, "input": input, "tool_use_id": id, "output": ["behavior": behavior]]
    }
    func fixture(events: [[String: Any]] = [], permissions: [[String: Any]] = [], successful: Bool = true, stopped: Bool = true) -> [String: Any] {
        var value: [String: Any] = [
            "schema": "claude-native-admission/v1",
            "strict_origin_status": "passed_local_fixture",
            "runner": [
                "schema": "native-sdk-runner/v1", "simulation": true, "fake_key": true, "events": events, "permissions": permissions,
                "result": ["type": "result", "subtype": successful ? "success" : "error", "is_error": !successful, "result": "FIXTURE_FINAL_TEXT"]
            ],
            "root_stop": ["cgroup_kill_elapsed_ms": 10, "observation_seconds": 3.003, "events": ["populated": stopped ? "0" : "1"], "writes_stable_for_3_seconds": stopped]
        ]
        // Data from unselected metadata must never be rendered in a replay.
        value["receipt"] = "FIXTURE_PRIVATE_RECEIPT"
        return value
    }
    func main(_ run: String, _ value: [String: Any]) -> [String: Any] {
        ["schema": "claude-code-macos-poc/combined-v1", "run": run, "native_admission_fixture": value,
         "native_postflight": ["files": ["native-admission-summary.json": ["evidence": value]]]]
    }
    func writeFixture(_ value: [String: Any], run: String = "native-1", root: URL) throws { try write(main(run, value), run: run, root: root) }

    check("replay_missing_directory_unavailable") {
        !ExecutionReplay.load(projectRoot: temporary.appendingPathComponent("absent").path).isAvailable
    }
    check("replay_empty_directory_unavailable") { !load(try directory()).isAvailable }
    check("replay_consistent_minimal_fixture_readable") {
        let root = try directory(); try writeFixture(fixture(), root: root)
        let replay = load(root)
        return replay.isAvailable && replay.run == "native-1" && replay.entries.count <= 160
    }
    check("replay_numeric_latest_10_over_9") {
        let root = try directory()
        try writeFixture(fixture(events: [assistant([["type": "text", "text": "OLDER_NINE"]])]), run: "native-9", root: root)
        try writeFixture(fixture(events: [assistant([["type": "text", "text": "LATEST_TEN"]])]), run: "native-10", root: root)
        let replay = load(root)
        return replay.isAvailable && replay.run == "native-10" && displayed(replay).contains("LATEST_TEN") && !displayed(replay).contains("OLDER_NINE")
    }
    check("replay_latest_chain_without_main_does_not_fallback") {
        let root = try directory(); try writeFixture(fixture(), run: "native-9", root: root)
        try write(["schema": "relay-chain-orchestration/v1", "run": "native-10"], run: "native-10", root: root, suffix: "-relay-chain")
        return !load(root).isAvailable && load(root).run == "native-10"
    }
    check("replay_unrecognized_names_do_not_select_latest") {
        let root = try directory(); try writeFixture(fixture(), run: "native-2", root: root)
        try write([:], run: "native-99-qualified", root: root)
        try write([:], run: "native-100-gateway", root: root)
        try write([:], run: "native-101-extra", root: root)
        return load(root).isAvailable && load(root).run == "native-2"
    }
    check("replay_latest_primary_postflight_mismatch_does_not_fallback") {
        let root = try directory(); try writeFixture(fixture(), run: "native-9", root: root)
        var value = main("native-10", fixture())
        value["native_postflight"] = ["files": ["native-admission-summary.json": ["evidence": fixture(successful: false)]]]
        try write(value, run: "native-10", root: root)
        return !load(root).isAvailable && load(root).run == "native-10"
    }
    check("replay_missing_persisted_copy_rejected") {
        let root = try directory(); var value = main("native-1", fixture()); value.removeValue(forKey: "native_postflight")
        try write(value, run: "native-1", root: root)
        return !load(root).isAvailable
    }
    check("replay_schema_and_run_boundaries_rejected") {
        var allRejected = true
        for changed in ["main_schema", "main_run", "fixture_schema", "runner_schema"] {
            let root = try directory(); var value = fixture()
            if changed == "fixture_schema" { value["schema"] = "unexpected/v1" }
            if changed == "runner_schema" { var runner = value["runner"] as! [String: Any]; runner["schema"] = "unexpected/v1"; value["runner"] = runner }
            var combined = main("native-1", value)
            if changed == "main_schema" { combined["schema"] = "unexpected/v1" }
            if changed == "main_run" { combined["run"] = "native-2" }
            try write(combined, run: "native-1", root: root)
            allRejected = allRejected && !load(root).isAvailable
        }
        return allRejected
    }
    check("replay_fake_source_flags_require_exact_true") {
        var allRejected = true
        for key in ["simulation", "fake_key"] {
            for variant in ["missing", "false", "numeric_true"] {
                let root = try directory(); var value = fixture(); var runner = value["runner"] as! [String: Any]
                if variant == "missing" { runner.removeValue(forKey: key) }
                else if variant == "false" { runner[key] = false }
                else { runner[key] = 1 }
                value["runner"] = runner
                try writeFixture(value, root: root)
                allRejected = allRejected && !load(root).isAvailable
            }
        }
        return allRejected
    }
    check("replay_malformed_latest_json_rejected_without_fallback") {
        let root = try directory(); try writeFixture(fixture(), run: "native-9", root: root)
        try Data("{ malformed".utf8).write(to: root.appendingPathComponent("host/evidence/native-10.json"))
        return !load(root).isAvailable && load(root).run == "native-10"
    }
    check("replay_json_over_8mib_rejected") {
        let root = try directory()
        var value = main("native-1", fixture()); value["ignored_padding"] = String(repeating: "x", count: 8_388_609)
        try write(value, run: "native-1", root: root)
        return !load(root).isAvailable
    }
    check("replay_selected_json_symlink_rejected") {
        let root = try directory()
        let outside = root.appendingPathComponent("owned-outside-evidence.json")
        try JSONSerialization.data(withJSONObject: main("native-1", fixture())).write(to: outside)
        try manager.createSymbolicLink(at: root.appendingPathComponent("host/evidence/native-1.json"), withDestinationURL: outside)
        return !load(root).isAvailable
    }
    check("replay_evidence_directory_symlink_rejected") {
        let root = try directory()
        let evidence = root.appendingPathComponent("host/evidence", isDirectory: true)
        let relocated = root.appendingPathComponent("owned-relocated-evidence", isDirectory: true)
        try manager.moveItem(at: evidence, to: relocated)
        try JSONSerialization.data(withJSONObject: main("native-1", fixture())).write(to: relocated.appendingPathComponent("native-1.json"))
        try manager.createSymbolicLink(at: evidence, withDestinationURL: relocated)
        return !load(root).isAvailable
    }
    check("replay_nonregular_directory_rejected") {
        let root = try directory()
        try manager.createDirectory(at: root.appendingPathComponent("host/evidence/native-1.json"), withIntermediateDirectories: false)
        return !load(root).isAvailable
    }
    check("replay_owned_fifo_rejected_without_blocking") {
        let root = try directory(); let fifo = root.appendingPathComponent("host/evidence/native-1.json")
        guard mkfifo(fifo.path, mode_t(0o600)) == 0 else { return false }
        return !load(root).isAvailable
    }
    check("replay_large_decimal_latest_does_not_overflow_or_fallback") {
        let root = try directory(); try writeFixture(fixture(), run: "native-9", root: root)
        let run = "native-999999999999999999999999999999999999"
        try write([:], run: run, root: root, suffix: "-relay-chain")
        return !load(root).isAvailable && load(root).run == run
    }
    check("replay_assistant_tool_order_and_subsequent_id_results") {
        let root = try directory()
        let events = [assistant([tool("Write", "write"), tool("Read", "read")]), result("read", "READ_RESULT"), result("write", "WRITE_RESULT"), assistant([tool("Bash", "bash")]), result("bash", "BASH_RESULT", error: false)]
        try writeFixture(fixture(events: events), root: root)
        let entries = tools(load(root))
        return entries.count == 3 && entries[0].title.contains("Write") && entries[1].title.contains("Read") && entries[2].title.contains("Bash") && entries[0].output?.contains("WRITE_RESULT") == true && entries[1].output?.contains("READ_RESULT") == true && entries[2].output?.contains("BASH_RESULT") == true
    }
    check("replay_missing_tool_result_is_information") {
        let root = try directory(); try writeFixture(fixture(events: [assistant([tool("Read", "missing")])]), root: root)
        let entries = tools(load(root)); return entries.count == 1 && entries[0].state == .information
    }
    check("replay_prior_tool_result_not_joined") {
        let root = try directory(); try writeFixture(fixture(events: [result("future", "EARLY_RESULT"), assistant([tool("Read", "future")])]), root: root)
        let entries = tools(load(root)); return entries.count == 1 && entries[0].state == .information && entries[0].output?.contains("EARLY_RESULT") != true
    }
    check("replay_error_flag_marks_failure_and_profile_warning_does_not") {
        let root = try directory()
        let events = [assistant([tool("Bash", "bash"), tool("Read", "read")]), result("bash", "/etc/profile: Permission denied\nOK", error: false), result("read", "EACCES: protected file", error: true)]
        try writeFixture(fixture(events: events), root: root)
        let entries = tools(load(root)); return entries.count == 2 && entries[0].state == .completed && entries[1].state == .failed
    }
    check("replay_fixture_permission_is_explicit_not_human") {
        let root = try directory(); let input: [String: Any] = ["file_path": "/fixture.txt"]
        try writeFixture(fixture(events: [assistant([tool("Read", "read", input)]), result("read", "OK")], permissions: [permission("Read", "read", input: input)]), root: root)
        return tools(load(root)).first?.approval == "测试许可：允许（非人工确认）"
    }
    check("replay_untrusted_permission_not_fixture_approved") {
        let root = try directory()
        try writeFixture(fixture(events: [assistant([tool("Read", "read")])], permissions: [permission("Read", "read", fixture: false)]), root: root)
        return tools(load(root)).first?.approval?.contains("允许") != true
    }
    check("replay_denial_is_not_allow_label") {
        let root = try directory()
        try writeFixture(fixture(events: [assistant([tool("Read", "read")])], permissions: [permission("Read", "read", behavior: "deny")]), root: root)
        return tools(load(root)).first?.approval?.contains("允许") != true
    }
    check("replay_permission_name_and_input_must_match") {
        var valid = true
        for recorded in [permission("Write", "read"), permission("Read", "read", input: ["file_path": "/different.txt"])] {
            let root = try directory(); try writeFixture(fixture(events: [assistant([tool("Read", "read")])], permissions: [recorded]), root: root)
            valid = valid && tools(load(root)).first?.approval?.contains("允许") != true
        }
        return valid
    }
    check("replay_duplicate_permissions_cannot_claim_allow") {
        let root = try directory(); let recorded = permission("Read", "read")
        try writeFixture(fixture(events: [assistant([tool("Read", "read")])], permissions: [recorded, recorded]), root: root)
        return tools(load(root)).first?.approval?.contains("允许") != true
    }
    check("replay_numeric_fixture_only_cannot_claim_allow") {
        let root = try directory(); var recorded = permission("Read", "read"); recorded["fixture_only"] = 1
        try writeFixture(fixture(events: [assistant([tool("Read", "read")])], permissions: [recorded]), root: root)
        return tools(load(root)).first?.approval?.contains("允许") != true
    }
    check("replay_permission_output_id_must_match") {
        let root = try directory(); var recorded = permission("Read", "read")
        recorded["output"] = ["behavior": "allow", "toolUseID": "different"]
        try writeFixture(fixture(events: [assistant([tool("Read", "read")])], permissions: [recorded]), root: root)
        return tools(load(root)).first?.approval?.contains("允许") != true
    }
    check("replay_duplicate_tool_ids_and_results_are_information") {
        var valid = true
        for events in [
            [assistant([tool("Read", "duplicate")]), result("duplicate", "FIRST"), assistant([tool("Read", "duplicate")]), result("duplicate", "SECOND")],
            [assistant([tool("Read", "duplicate")]), result("duplicate", "FIRST"), result("duplicate", "SECOND")]
        ] {
            let root = try directory(); try writeFixture(fixture(events: events), root: root)
            let entries = tools(load(root)); valid = valid && entries.count == 1 && entries[0].state == .information
        }
        return valid
    }
    check("replay_numeric_error_flag_cannot_claim_completion") {
        let root = try directory(); var returned = result("read", "OK")
        returned["message"] = ["content": [["type": "tool_result", "tool_use_id": "read", "content": "OK", "is_error": 0]]]
        try writeFixture(fixture(events: [assistant([tool("Read", "read")]), returned]), root: root)
        return tools(load(root)).first?.state == .information
    }
    check("replay_unknown_payload_and_initial_user_metadata_omitted") {
        let root = try directory()
        var value = fixture(events: [
            ["type": "unknown", "payload": "FIXTURE_UNKNOWN_SECRET"],
            ["type": "user", "message": ["content": [["type": "text", "text": "FIXTURE_USER_SECRET"]]]],
            ["type": "system", "metadata": ["token": "FIXTURE_METADATA_SECRET"]],
            assistant([["type": "text", "text": "VISIBLE_ASSISTANT_TEXT"], ["type": "thinking", "thinking": "FIXTURE_THINKING_SECRET"], tool("Read", "read", ["file_path": "/fixture.txt", "unexpected": "FIXTURE_PARAMETER_SECRET"])]),
            result("read", [["type": "text", "text": "VISIBLE_RESULT_TEXT"], ["type": "unknown", "payload": "FIXTURE_RESULT_SECRET"]])
        ])
        var runner = value["runner"] as! [String: Any]; runner["raw"] = ["token": "FIXTURE_RAW_SECRET"]; value["runner"] = runner
        try writeFixture(value, root: root)
        let rendered = displayed(load(root))
        return rendered.contains("VISIBLE_ASSISTANT_TEXT") && rendered.contains("VISIBLE_RESULT_TEXT") && !["FIXTURE_UNKNOWN_SECRET", "FIXTURE_USER_SECRET", "FIXTURE_METADATA_SECRET", "FIXTURE_THINKING_SECRET", "FIXTURE_PARAMETER_SECRET", "FIXTURE_RESULT_SECRET", "FIXTURE_RAW_SECRET", "FIXTURE_PRIVATE_RECEIPT"].contains(where: rendered.contains)
    }
    check("replay_unknown_tool_cannot_surface_unwhitelisted_input") {
        let root = try directory(); try writeFixture(fixture(events: [assistant([tool("UnknownTool", "unknown", ["payload": "FIXTURE_UNKNOWN_TOOL_SECRET"])]), result("unknown", "UNKNOWN_TOOL_RESULT")]), root: root)
        let replay = load(root)
        return !displayed(replay).contains("FIXTURE_UNKNOWN_TOOL_SECRET") && tools(replay).allSatisfy { $0.state == .information }
    }
    check("replay_text_credentials_are_masked") {
        let root = try directory()
        let secretText = "receipt=SECRET_RECEIPT api_key: SECRET_API_KEY Bearer SECRET_BEARER client-token = SECRET_CLIENT_TOKEN"
        try writeFixture(fixture(events: [assistant([["type": "text", "text": secretText], tool("Bash", "bash", ["command": secretText])]), result("bash", secretText)]), root: root)
        let rendered = displayed(load(root))
        return rendered.contains("已隐藏") && !["SECRET_RECEIPT", "SECRET_API_KEY", "SECRET_BEARER", "SECRET_CLIENT_TOKEN"].contains(where: rendered.contains)
    }
    check("replay_mixed_unknown_tool_return_preserves_known_text_without_completion") {
        let root = try directory()
        try writeFixture(fixture(events: [assistant([tool("Read", "read")]), result("read", [["type": "text", "text": "KNOWN_MIXED_TEXT"], ["type": "unknown", "secret": "UNKNOWN_MIXED_SECRET"]])]), root: root)
        let replay = load(root); let entries = tools(replay)
        return entries.count == 1 && entries[0].state == .information && entries[0].output?.contains("KNOWN_MIXED_TEXT") == true && !displayed(replay).contains("UNKNOWN_MIXED_SECRET")
    }
    check("replay_successful_result_and_stop_statuses_completed") {
        let root = try directory(); try writeFixture(fixture(), root: root)
        return load(root).entries.filter { $0.kind == .status && $0.state == .completed }.count == 2
    }
    check("replay_missing_terminal_evidence_never_completed") {
        let root = try directory(); var value = fixture(); value.removeValue(forKey: "root_stop")
        var runner = value["runner"] as! [String: Any]; runner.removeValue(forKey: "result"); value["runner"] = runner
        try writeFixture(value, root: root)
        let replay = load(root); return replay.isAvailable && replay.entries.allSatisfy { $0.state != .completed }
    }
    check("replay_failed_result_and_incomplete_stop_not_completed") {
        let root = try directory(); try writeFixture(fixture(successful: false, stopped: false), root: root)
        let replay = load(root); return replay.isAvailable && replay.entries.allSatisfy { $0.state != .completed }
    }
    check("replay_stop_requires_full_observation_and_nonnegative_elapsed") {
        var valid = true
        for stop in [
            ["cgroup_kill_elapsed_ms": 10, "observation_seconds": 2.999, "events": ["populated": "0"], "writes_stable_for_3_seconds": true],
            ["cgroup_kill_elapsed_ms": -1, "observation_seconds": 3.003, "events": ["populated": "0"], "writes_stable_for_3_seconds": true]
        ] as [[String: Any]] {
            let root = try directory(); var value = fixture(successful: false); value["root_stop"] = stop
            try writeFixture(value, root: root)
            valid = valid && load(root).entries.allSatisfy { $0.state != .completed }
        }
        return valid
    }
    check("replay_terminal_boolean_and_numeric_types_are_distinct") {
        let root = try directory(); var value = fixture(); var runner = value["runner"] as! [String: Any]
        runner["result"] = ["type": "result", "subtype": "success", "is_error": 0]; value["runner"] = runner
        value["root_stop"] = ["cgroup_kill_elapsed_ms": true, "observation_seconds": 3.003, "events": ["populated": "0"], "writes_stable_for_3_seconds": true]
        try writeFixture(value, root: root)
        return load(root).entries.allSatisfy { $0.state != .completed }
    }
    check("replay_text_bounds") {
        let root = try directory(); let long = String(repeating: "界", count: 20_000)
        try writeFixture(fixture(events: [assistant([["type": "text", "text": long]])]), root: root)
        let replay = load(root)
        return replay.isAvailable && replay.entries.allSatisfy { [$0.title, $0.subtitle, $0.parameters ?? "", $0.output ?? "", $0.approval ?? ""].allSatisfy { $0.count <= 16_384 } }
    }
    check("replay_entry_bounds") {
        let root = try directory(); let content = (0..<200).map { ["type": "text", "text": "BOUNDED_ENTRY_\($0)"] }
        try writeFixture(fixture(events: [assistant(content)]), root: root)
        let replay = load(root)
        return replay.isAvailable && !replay.entries.isEmpty && replay.entries.count <= 160
    }
    check("replay_over_4096_events_rejected") {
        let root = try directory(); try writeFixture(fixture(events: Array(repeating: ["type": "unknown"], count: 4097)), root: root)
        return !load(root).isAvailable
    }
    check("replay_actual_native23_tools_and_outcomes") {
        let root = try directory()
        let native23 = URL(fileURLWithPath: projectRoot).appendingPathComponent("host/evidence/native-23.json")
        try manager.copyItem(at: native23, to: root.appendingPathComponent("host/evidence/native-23.json"))
        let replay = load(root)
        let entries = tools(replay)
        return replay.isAvailable && replay.run == "native-23" && entries.count == 6 && entries.filter { $0.state == .completed }.count == 4 && entries.filter { $0.state == .failed }.count == 2 && entries.map(\.title).enumerated().allSatisfy { index, title in title.contains(["Write", "Read", "Edit", "Bash", "Read", "Write"][index]) }
    }
    // Perform cleanup before returning so a cleanup failure is included in the result.
    do { try manager.removeItem(at: temporary) }
    catch { checks.append(("replay_owned_temporary_directory_removed", false)) }
    return checks
}
