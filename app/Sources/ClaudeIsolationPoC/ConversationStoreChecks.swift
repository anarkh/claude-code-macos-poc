import Foundation

func conversationStoreChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("conversation_store_" + name, passed)) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-store-checks-\(UUID().uuidString)", isDirectory: true)
    let fileURL = root.appendingPathComponent("private/conversations.json")
    let store = FileConversationStore(fileURL: fileURL)
    let date = Date(timeIntervalSinceReferenceDate: 8_123_456)
    let user = ConversationMessage(role: .user, text: "Explain `foo()`.", originalText: "解释 `foo()`。", state: .complete, createdAt: date)
    let assistant = ConversationMessage(role: .assistant, text: "It calls foo.", translation: "它调用 foo。", state: .complete, createdAt: date)
    let activity = ConversationMessage(role: .activity, text: "模型执行中", state: .running, createdAt: date)
    let first = ConversationRecord(title: "解释函数", createdAt: date, updatedAt: date, draft: "待发送的草稿", targetLanguage: "en", messages: [user, assistant, activity])
    let second = ConversationRecord(title: "日语会话", createdAt: date, updatedAt: date, draft: "另一个草稿", targetLanguage: "ja")
    let snapshot = ConversationSnapshot(selectedID: first.id, conversations: [first, second])
    func expectFailure(_ name: String, _ expected: ConversationStoreFailure, operation: () throws -> Void) {
        do { try operation(); check(name, false) }
        catch let error as ConversationStoreFailure { check(name, error == expected && !error.message.isEmpty) }
        catch { check(name, false) }
    }
    do {
        check("missing_file_is_empty", try store.load() == .empty)
        try store.save(snapshot)
        check("persisted_roundtrip", try store.load() == snapshot)
        check("restart_restores_selected_session", try FileConversationStore(fileURL: fileURL).load().selectedID == first.id)
        let readback = try store.load()
        check("restart_restores_both_drafts_and_languages", readback.conversations.map(\.draft) == [first.draft, second.draft] && readback.conversations.map(\.targetLanguage) == ["en", "ja"])
        check("original_and_translation_preserved", readback.conversations[0].messages[0].originalText == user.originalText && readback.conversations[0].messages[1].translation == assistant.translation)
        check("store_does_not_replay_or_normalize_running_state", readback.conversations[0].messages[2].state == .running)
        check("private_file_permissions", (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        check("private_folder_permissions", (try FileManager.default.attributesOfItem(atPath: fileURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        check("old_messages_decode_without_run_or_trace", readback.conversations[0].messages.allSatisfy { $0.runID == nil && $0.requestTraces == nil })
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        let records = object?["conversations"] as? [[String: Any]]
        let messages = records?.first?["messages"] as? [[String: Any]]
        check("snapshot_has_only_session_fields", object.map { Set($0.keys) == Set(["schemaVersion", "selectedID", "conversations"]) } ?? false)
        check("record_has_only_session_fields", records?.allSatisfy { Set($0.keys) == Set(["id", "title", "createdAt", "updatedAt", "draft", "targetLanguage", "messages"]) } ?? false)
        let allowed = Set(["id", "role", "text", "originalText", "translation", "state", "error", "createdAt"])
        check("message_has_only_message_fields", messages?.allSatisfy { Set($0.keys).isSubset(of: allowed) } ?? false)
        let runID = UUID()
        let runUser = ConversationMessage(role: .user, text: "trace input", createdAt: date, runID: runID)
        let failedTrace = requestTraceFixture(runID: runID, phase: .error)
        let runAssistant = ConversationMessage(role: .assistant, text: "partial reply", state: .failed,
            error: "模型服务连接失败。", createdAt: date, runID: runID, requestTraces: [failedTrace])
        let tracedRecord = ConversationRecord(messages: [runUser, runAssistant])
        let traceSnapshot = ConversationSnapshot(selectedID: tracedRecord.id, conversations: [tracedRecord])
        let traceFile = root.appendingPathComponent("trace/conversations.json")
        let traceStore = FileConversationStore(fileURL: traceFile)
        try traceStore.save(traceSnapshot)
        let traceRestart = try FileConversationStore(fileURL: traceFile).load()
        check("failed_trace_survives_restart_with_actual_body", traceRestart == traceSnapshot && traceRestart.conversations[0].messages[1].requestTraces?.first?.body == failedTrace.body)
        let traceObject = try JSONSerialization.jsonObject(with: Data(contentsOf: traceFile)) as! [String: Any]
        let traceRecords = traceObject["conversations"] as! [[String: Any]]
        let traceMessages = traceRecords[0]["messages"] as! [[String: Any]]
        check("actual_body_persisted_once_for_both_message_links", traceMessages[0]["requestTraces"] == nil && (traceMessages[1]["requestTraces"] as? [[String: Any]])?.count == 1 && traceMessages[0]["runID"] as? String == traceMessages[1]["runID"] as? String)
        check("trace_file_remains_private", (try FileManager.default.attributesOfItem(atPath: traceFile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        var duplicateBodies = traceSnapshot
        duplicateBodies.conversations[0].messages[0].requestTraces = [failedTrace]
        expectFailure("user_cannot_duplicate_persisted_trace", .invalidFormat) { try traceStore.save(duplicateBodies) }
        var foreignTrace = traceSnapshot
        foreignTrace.conversations[0].messages[1].requestTraces = [requestTraceFixture(runID: UUID(), phase: .response)]
        expectFailure("foreign_run_trace_cannot_be_persisted", .invalidFormat) { try traceStore.save(foreignTrace) }
        var duplicateAttempts = traceSnapshot
        duplicateAttempts.conversations[0].messages[1].requestTraces = [failedTrace, failedTrace]
        expectFailure("duplicate_attempt_cannot_be_persisted", .invalidFormat) { try traceStore.save(duplicateAttempts) }
        let isolated = FileConversationStore(fileURL: root.appendingPathComponent("another/conversations.json"))
        check("another_store_is_empty", try isolated.load() == .empty)
        try isolated.save(.init(selectedID: second.id, conversations: [second]))
        check("another_store_does_not_change_history", try store.load() == snapshot)

        var updated = snapshot
        updated.conversations[0].draft = "修改后的草稿"
        updated.selectedID = second.id
        try store.save(updated)
        check("replace_persists_current_session_and_draft", try store.load() == updated)
        let bytesBeforeFailure = try Data(contentsOf: fileURL)
        let failingStore = FileConversationStore(fileURL: fileURL, atomicReplace: { _, _ in throw ConversationStoreFailure.saveFailed })
        expectFailure("atomic_replace_failure_reported", .saveFailed) { try failingStore.save(snapshot) }
        check("atomic_replace_failure_preserves_previous_bytes", try Data(contentsOf: fileURL) == bytesBeforeFailure)
        check("atomic_replace_failure_cleans_temporary_file", try FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path).sorted() == ["conversations.json"])
        check("failed_save_preserves_readable_history", try store.load() == updated)

        var duplicateRecords = updated
        duplicateRecords.conversations.append(first)
        expectFailure("duplicate_conversation_save_rejected", .duplicateConversationID) { try store.save(duplicateRecords) }
        var duplicateMessages = updated
        duplicateMessages.conversations[1].messages.append(user)
        expectFailure("duplicate_message_across_sessions_rejected", .duplicateMessageID) { try store.save(duplicateMessages) }
        var badSelection = updated; badSelection.selectedID = UUID()
        expectFailure("unknown_selected_session_rejected", .invalidSelection) { try store.save(badSelection) }
        var badLanguage = updated; badLanguage.conversations[0].targetLanguage = "zh"
        expectFailure("unknown_target_language_rejected", .invalidLanguage) { try store.save(badLanguage) }
        var futureVersion = updated; futureVersion.schemaVersion = 4
        expectFailure("unsupported_save_version_rejected", .unsupportedVersion) { try store.save(futureVersion) }
        check("validation_failure_preserves_previous_bytes", try Data(contentsOf: fileURL) == bytesBeforeFailure)

        func invalidStored(_ name: String, _ expected: ConversationStoreFailure, mutate: (inout [String: Any]) -> Void) throws {
            var payload = try JSONSerialization.jsonObject(with: bytesBeforeFailure) as! [String: Any]
            mutate(&payload)
            let invalidBytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try invalidBytes.write(to: fileURL)
            expectFailure(name + "_load", expected) { _ = try store.load() }
            expectFailure(name + "_save_preserves_bad_input", expected) { try store.save(snapshot) }
            check(name + "_original_bytes_retained", try Data(contentsOf: fileURL) == invalidBytes)
            try bytesBeforeFailure.write(to: fileURL)
        }
        try invalidStored("unsupported_file_version", .unsupportedVersion) { $0["schemaVersion"] = 4 }
        try invalidStored("unknown_snapshot_field", .invalidFormat) { $0["apiKey"] = "fixture-only-not-a-credential" }
        try invalidStored("duplicate_record_file", .duplicateConversationID) { payload in
            var records = payload["conversations"] as! [[String: Any]]; records.append(records[0]); payload["conversations"] = records
        }
        try invalidStored("invalid_role_file", .invalidFormat) { payload in
            var records = payload["conversations"] as! [[String: Any]]
            var messages = records[0]["messages"] as! [[String: Any]]
            messages[0]["role"] = "system"; records[0]["messages"] = messages; payload["conversations"] = records
        }
        try invalidStored("invalid_state_file", .invalidFormat) { payload in
            var records = payload["conversations"] as! [[String: Any]]
            var messages = records[0]["messages"] as! [[String: Any]]
            messages[0]["state"] = "unknown"; records[0]["messages"] = messages; payload["conversations"] = records
        }
        try invalidStored("unknown_message_field", .invalidFormat) { payload in
            var records = payload["conversations"] as! [[String: Any]]
            var messages = records[0]["messages"] as! [[String: Any]]
            messages[0]["apiKey"] = "fixture-only-not-a-credential"; records[0]["messages"] = messages; payload["conversations"] = records
        }
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: fileURL)
        expectFailure("corrupt_file_load_reported", .invalidFormat) { _ = try store.load() }
        expectFailure("corrupt_file_not_overwritten_by_new_session", .invalidFormat) { try store.save(.empty) }
        check("corrupt_file_retained", try Data(contentsOf: fileURL) == corrupt)
        try bytesBeforeFailure.write(to: fileURL)
        var oversized = updated; oversized.conversations[0].draft = String(repeating: "x", count: FileConversationStore.maximumBytes)
        expectFailure("oversized_save_rejected", .tooLarge) { try store.save(oversized) }
        check("oversized_save_preserves_previous_bytes", try Data(contentsOf: fileURL) == bytesBeforeFailure)
        try Data(repeating: 32, count: FileConversationStore.maximumBytes + 1).write(to: fileURL)
        expectFailure("oversized_stored_file_rejected", .tooLarge) { _ = try store.load() }
        try bytesBeforeFailure.write(to: fileURL)
        let directoryStore = FileConversationStore(fileURL: root.appendingPathComponent("private", isDirectory: true))
        expectFailure("directory_destination_read_rejected", .readFailed) { _ = try directoryStore.load() }
        expectFailure("directory_destination_save_rejected", .readFailed) { try directoryStore.save(.empty) }
        let link = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fileURL)
        let linkedStore = FileConversationStore(fileURL: link)
        expectFailure("symlink_read_rejected", .readFailed) { _ = try linkedStore.load() }
        expectFailure("symlink_save_rejected", .readFailed) { try linkedStore.save(snapshot) }
        check("symlink_target_preserved", try Data(contentsOf: fileURL) == bytesBeforeFailure)
        try FileManager.default.removeItem(at: root)
        check("test_directory_removed", !FileManager.default.fileExists(atPath: root.path))
    } catch {
        check("setup_or_operation_failure", false)
        if FileManager.default.fileExists(atPath: root.path) {
            do { try FileManager.default.removeItem(at: root) }
            catch { check("failed_test_cleanup", false) }
        }
    }
    results.append(contentsOf: conversationProjectStoreChecks())
    results.append(contentsOf: conversationTracePrivacyStoreChecks())
    return results
}

private func conversationProjectStoreChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("conversation_store_project_" + name, passed)) }
    func expectInvalid(_ name: String, operation: () throws -> Void) {
        do { try operation(); check(name, false) }
        catch let failure as ConversationStoreFailure { check(name, failure == .invalidFormat) }
        catch { check(name, false) }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-project-store-\(UUID().uuidString)", isDirectory: true)
    let project = root.appendingPathComponent("selected-project", isDirectory: true)
    let fileURL = root.appendingPathComponent("conversations.json")
    let store = FileConversationStore(fileURL: fileURL)
    let record = ConversationRecord(title: "Project history", draft: "Preserved draft", projectDirectory: project.path,
                                    messages: [.init(role: .user, text: "Preserved project message")])
    let snapshot = ConversationSnapshot(selectedID: record.id, conversations: [record])
    do {
        check("new_snapshot_defaults_to_v3", ConversationSnapshot().schemaVersion == 3)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try store.save(snapshot)
        let originalBytes = try Data(contentsOf: fileURL)
        check("v3_selected_directory_survives_restart", try FileConversationStore(fileURL: fileURL).load() == snapshot)
        let payload = try JSONSerialization.jsonObject(with: originalBytes) as! [String: Any]
        let records = payload["conversations"] as! [[String: Any]]
        check("v3_directory_is_persisted", payload["schemaVersion"] as? Int == 3 && records[0]["projectDirectory"] as? String == project.path)
        try FileManager.default.removeItem(at: project)
        let missingDirectoryReadback = try store.load()
        check("missing_directory_preserves_readable_history", !FileManager.default.fileExists(atPath: project.path) && missingDirectoryReadback == snapshot)
        check("missing_directory_does_not_rewrite_history", try Data(contentsOf: fileURL) == originalBytes)

        func rejectStored(_ name: String, bytes: Data, destination: URL, validBytes: Data) throws {
            try bytes.write(to: destination)
            let invalidStore = FileConversationStore(fileURL: destination)
            expectInvalid(name + "_read_rejected") { _ = try invalidStore.load() }
            expectInvalid(name + "_replacement_rejected") { try invalidStore.save(.empty) }
            check(name + "_original_bytes_retained", try Data(contentsOf: destination) == bytes)
            try validBytes.write(to: destination)
        }
        let invalidPaths = ["", ".", "relative/project", "/", "//tmp/project", "/tmp//project", "/tmp/project/", "/tmp/./project", "/tmp/../project", "/tmp/project\0suffix"]
        for (index, path) in invalidPaths.enumerated() {
            var invalid = snapshot
            invalid.conversations[0].projectDirectory = path
            expectInvalid("invalid_path_\(index)_save_rejected") { try store.save(invalid) }
            check("invalid_path_\(index)_failed_save_preserves_history", try Data(contentsOf: fileURL) == originalBytes)
            try rejectStored("invalid_path_\(index)", bytes: JSONEncoder().encode(invalid), destination: fileURL, validBytes: originalBytes)
        }

        for version in [1, 2] {
            var legacy = snapshot
            legacy.schemaVersion = version
            legacy.conversations[0].projectDirectory = nil
            let legacyFile = root.appendingPathComponent("v\(version).json")
            let legacyStore = FileConversationStore(fileURL: legacyFile)
            try legacyStore.save(legacy)
            let legacyBytes = try Data(contentsOf: legacyFile)
            let readback = try FileConversationStore(fileURL: legacyFile).load()
            let legacyBytesAfterLoad = try Data(contentsOf: legacyFile)
            check("v\(version)_reads_without_directory_or_rewrite", readback == legacy && readback.conversations[0].projectDirectory == nil && legacyBytesAfterLoad == legacyBytes)
            var invalidLegacy = legacy
            invalidLegacy.conversations[0].projectDirectory = project.path
            expectInvalid("v\(version)_directory_save_rejected") { try legacyStore.save(invalidLegacy) }
            check("v\(version)_failed_save_preserves_history", try Data(contentsOf: legacyFile) == legacyBytes)
            for (name, value) in [("path", project.path as Any), ("null", NSNull() as Any)] {
                var invalidPayload = try JSONSerialization.jsonObject(with: legacyBytes) as! [String: Any]
                var invalidRecords = invalidPayload["conversations"] as! [[String: Any]]
                invalidRecords[0]["projectDirectory"] = value
                invalidPayload["conversations"] = invalidRecords
                try rejectStored("v\(version)_directory_\(name)", bytes: JSONSerialization.data(withJSONObject: invalidPayload, options: [.sortedKeys]), destination: legacyFile, validBytes: legacyBytes)
            }
        }

        let runID = UUID()
        let traces = (1...25).map { requestTraceFixture(runID: runID, attempt: $0, phase: .response) }
        let tracedRecord = ConversationRecord(projectDirectory: project.path, messages: [
            .init(role: .user, text: "Project turn", runID: runID),
            .init(role: .assistant, text: "Project result", runID: runID, requestTraces: Array(traces.prefix(24)))
        ])
        var tracedSnapshot = ConversationSnapshot(selectedID: tracedRecord.id, conversations: [tracedRecord])
        let traceFile = root.appendingPathComponent("traces.json")
        let traceStore = FileConversationStore(fileURL: traceFile)
        try traceStore.save(tracedSnapshot)
        let traceBytes = try Data(contentsOf: traceFile)
        check("v3_twenty_four_traces_roundtrip", try FileConversationStore(fileURL: traceFile).load() == tracedSnapshot)
        tracedSnapshot.conversations[0].messages[1].requestTraces = traces
        expectInvalid("v3_twenty_five_traces_save_rejected") { try traceStore.save(tracedSnapshot) }
        check("v3_trace_limit_failure_preserves_history", try Data(contentsOf: traceFile) == traceBytes)
        try rejectStored("v3_twenty_five_traces", bytes: JSONEncoder().encode(tracedSnapshot), destination: traceFile, validBytes: traceBytes)
        for version in [1, 2] {
            tracedSnapshot.schemaVersion = version
            tracedSnapshot.conversations[0].projectDirectory = nil
            tracedSnapshot.conversations[0].messages[1].requestTraces = Array(traces.prefix(3))
            try traceStore.save(tracedSnapshot)
            let legacyTraceBytes = try Data(contentsOf: traceFile)
            check("v\(version)_three_traces_roundtrip", try traceStore.load() == tracedSnapshot)
            tracedSnapshot.conversations[0].messages[1].requestTraces = Array(traces.prefix(4))
            expectInvalid("v\(version)_four_traces_save_rejected") { try traceStore.save(tracedSnapshot) }
            check("v\(version)_trace_limit_failure_preserves_history", try Data(contentsOf: traceFile) == legacyTraceBytes)
            try rejectStored("v\(version)_four_traces", bytes: JSONEncoder().encode(tracedSnapshot), destination: traceFile, validBytes: legacyTraceBytes)
        }
    } catch { check("setup_or_operation_failure", false) }
    if FileManager.default.fileExists(atPath: root.path) {
        do { try FileManager.default.removeItem(at: root) }
        catch { check("temporary_store_cleanup", false) }
    }
    return results
}

private func conversationTracePrivacyStoreChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("conversation_store_privacy_" + name, passed)) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-trace-privacy-\(UUID().uuidString)", isDirectory: true)
    let fileURL = root.appendingPathComponent("conversations.json")
    let store = FileConversationStore(fileURL: fileURL)
    let runID = UUID()
    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let bodyMarker = "synthetic-sensitive-body-only-in-diagnostic-record"
    let body = "{\"model\":\"deepseek-flash[1m]\",\"messages\":[{\"role\":\"user\",\"content\":\"\(bodyMarker)\"}]}"
    let legacy = requestTraceFixture(runID: runID, phase: .response, body: body)
    let user = ConversationMessage(role: .user, text: "preserved user message", createdAt: capturedAt, runID: runID)
    let assistant = ConversationMessage(role: .assistant, text: "preserved assistant answer", createdAt: capturedAt,
                                        runID: runID, requestTraces: [legacy])
    let record = ConversationRecord(title: "preserved title", createdAt: capturedAt, updatedAt: capturedAt,
                                    draft: "preserved draft", messages: [user, assistant])
    let legacySnapshot = ConversationSnapshot(schemaVersion: 1, selectedID: record.id, conversations: [record])
    do {
        try store.save(legacySnapshot)
        let legacyBytes = try Data(contentsOf: fileURL)
        let legacyReadback = try FileConversationStore(fileURL: fileURL).load()
        let legacyBytesAfterLoad = try Data(contentsOf: fileURL)
        check("v1_snapshot_reads_without_rewriting", legacyReadback == legacySnapshot && legacyBytesAfterLoad == legacyBytes)
        check("v1_body_survives_without_assumed_retention", legacyReadback.conversations[0].messages[1].requestTraces?.first?.removingExpiredBody(now: capturedAt.addingTimeInterval(365 * 86_400)) == legacy)
        check("new_snapshot_defaults_to_v3", ConversationSnapshot().schemaVersion == 3)

        let summary = legacy.persisted(captureBody: false, capturedAt: capturedAt)
        let full = legacy.persisted(captureBody: true, capturedAt: capturedAt)
        let expired = full.removingExpiredBody(now: capturedAt.addingTimeInterval(86_400))
        let removedLegacy = legacy.removingBody()
        for (name, trace) in [("summary", summary), ("full", full), ("expired", expired), ("removed_legacy", removedLegacy)] {
            var next = legacySnapshot
            next.schemaVersion = 2
            next.conversations[0].messages[1].requestTraces = [trace]
            try store.save(next)
            let readback = try FileConversationStore(fileURL: fileURL).load()
            check("v2_\(name)_roundtrip", readback == next)
            check("v2_\(name)_preserves_conversation", readback.conversations[0].id == record.id && readback.selectedID == record.id && readback.conversations[0].title == record.title && readback.conversations[0].draft == record.draft && readback.conversations[0].messages[0] == user && readback.conversations[0].messages[1].text == assistant.text)
            let bytes = try Data(contentsOf: fileURL)
            let persisted = String(decoding: bytes, as: UTF8.self)
            check("v2_\(name)_body_presence_matches_policy", persisted.contains(bodyMarker) == trace.hasBody)
            check("v2_\(name)_keeps_original_body_byte_count", readback.conversations[0].messages[1].requestTraces?.first?.bodyBytes == legacy.bodyBytes)
        }
        let projectFile = root.appendingPathComponent("project/conversations.json")
        let projectStore = FileConversationStore(fileURL: projectFile)
        var projectSnapshot = legacySnapshot
        projectSnapshot.schemaVersion = 3
        projectSnapshot.conversations[0].projectDirectory = root.appendingPathComponent("selected-project").path
        for (name, trace) in [("summary", summary), ("full", full), ("expired", expired), ("removed_legacy", removedLegacy)] {
            projectSnapshot.conversations[0].messages[1].requestTraces = [trace]
            try projectStore.save(projectSnapshot)
            let readback = try FileConversationStore(fileURL: projectFile).load()
            check("v3_\(name)_preserves_directory_and_conversation", readback == projectSnapshot && readback.conversations[0].projectDirectory == projectSnapshot.conversations[0].projectDirectory)
            check("v3_\(name)_body_presence_matches_policy", String(decoding: try Data(contentsOf: projectFile), as: UTF8.self).contains(bodyMarker) == trace.hasBody)
        }
        let validBytes = try Data(contentsOf: fileURL)
        var invalid = try JSONSerialization.jsonObject(with: validBytes) as! [String: Any]
        var records = invalid["conversations"] as! [[String: Any]]
        var messages = records[0]["messages"] as! [[String: Any]]
        var traces = messages[1]["requestTraces"] as! [[String: Any]]
        traces[0].removeValue(forKey: "expires_at")
        messages[1]["requestTraces"] = traces
        records[0]["messages"] = messages
        invalid["conversations"] = records
        let invalidBytes = try JSONSerialization.data(withJSONObject: invalid, options: [.sortedKeys])
        try invalidBytes.write(to: fileURL)
        do { _ = try store.load(); check("incompatible_v2_trace_read_rejected", false) }
        catch let failure as ConversationStoreFailure { check("incompatible_v2_trace_read_rejected", failure == .invalidFormat) }
        catch { check("incompatible_v2_trace_read_rejected", false) }
        do { try store.save(.empty); check("incompatible_v2_trace_save_rejected", false) }
        catch let failure as ConversationStoreFailure { check("incompatible_v2_trace_save_rejected", failure == .invalidFormat) }
        catch { check("incompatible_v2_trace_save_rejected", false) }
        check("incompatible_v2_trace_original_bytes_retained", try Data(contentsOf: fileURL) == invalidBytes)
    } catch { check("setup_or_operation_failure", false) }
    if FileManager.default.fileExists(atPath: root.path) {
        do { try FileManager.default.removeItem(at: root) }
        catch { check("temporary_store_cleanup", false) }
    }
    return results
}
