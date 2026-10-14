import Foundation

/// Uses only temporary Markdown and app-owned JSON. It never calls a model, Keychain or a skill script.
@MainActor
func textSkillsChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("text_skills_" + name, passed)) }
    func expectFailure(_ name: String, _ expected: TextSkillFailure, operation: () throws -> Void) {
        do { try operation(); check(name, false) }
        catch let failure as TextSkillFailure { check(name, failure == expected && !failure.message.isEmpty) }
        catch { check(name, false) }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("text-skills-checks-\(UUID().uuidString)", isDirectory: true)
    let fileURL = root.appendingPathComponent("private/text-skills.json")
    let store = FileTextSkillStore(fileURL: fileURL)
    func markdown(_ name: String, _ body: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("SKILL.md")
        try Data(body.utf8).write(to: url)
        return url
    }
    do {
        check("missing_file_is_empty", try store.load() == .empty)
        let model = SkillsViewModel(store: store)
        check("startup_does_not_create_persistence", model.skills.isEmpty && model.error == nil && !FileManager.default.fileExists(atPath: fileURL.path))
        let body = "\n# Review\n\n    preserve indentation\nReturn Markdown with 日本語 and 中文.\n!`this-is-static-text`\n"
        let source = try markdown("external-review", "---\nname: \"review-text\" # human-readable name\ndescription: 'Review ''carefully'' # with examples'\nallowed-tools: Bash\n---\n" + body)
        let ignoredScript = source.deletingLastPathComponent().appendingPathComponent("ignored.sh")
        try Data("this file is neither loaded nor executed".utf8).write(to: ignoredScript)
        model.importSkill(at: source)
        check("import_parses_quoted_name", model.skills.first?.name == "review-text")
        check("import_parses_single_quote_escapes_and_hash", model.skills.first?.summary == "Review 'carefully' # with examples")
        check("import_preserves_markdown_and_static_command_text", model.skills.first?.content == body)
        let disabledContexts = try model.enabledContexts()
        check("import_is_disabled_until_explicit_enable", model.skills.first?.isEnabled == false && disabledContexts.isEmpty)
        check("import_persists_snapshot_without_host_source_path", !(String(decoding: try Data(contentsOf: fileURL), as: UTF8.self).contains(root.path)))
        check("private_file_permissions", (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        check("private_directory_permissions", (try FileManager.default.attributesOfItem(atPath: fileURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        guard let original = model.skills.first else { throw TextSkillFailure.invalidFormat }
        model.setEnabled(original.id, enabled: true)
        let enabledSnapshot = try store.load()
        check("enable_persists_before_becoming_context", model.skills.first?.isEnabled == true && enabledSnapshot.skills.first?.isEnabled == true)
        check("context_contains_only_name_and_text", try model.enabledContexts() == [.init(name: "review-text", content: body)])
        let restarted = SkillsViewModel(store: FileTextSkillStore(fileURL: fileURL))
        check("restart_restores_enabled_snapshot", restarted.skills == model.skills && restarted.error == nil)
        let sourceBytes = try Data(contentsOf: source)
        model.importSkill(at: source)
        check("duplicate_import_preserves_existing_snapshot", model.skills.count == 1 && model.skills.first?.id == original.id && model.error == TextSkillFailure.duplicateName.message)
        let caseDuplicate = try markdown("case-duplicate", "---\nname: REVIEW-TEXT\n---\nNew instructions.")
        model.importSkill(at: caseDuplicate)
        check("duplicate_name_is_case_insensitive", model.skills.count == 1 && model.error == TextSkillFailure.duplicateName.message)
        try Data("---\nname: changed\n---\nChanged source after import.".utf8).write(to: source)
        check("source_changes_do_not_refresh_snapshot", try model.enabledContexts() == [.init(name: "review-text", content: body)])
        try FileManager.default.removeItem(at: source)
        check("deleted_source_does_not_disable_snapshot", try model.enabledContexts() == [.init(name: "review-text", content: body)])
        try sourceBytes.write(to: source)
        model.setEnabled(original.id, enabled: false)
        check("disable_removes_next_context", try model.enabledContexts().isEmpty)
        model.remove(original.id)
        let removedSnapshot = try store.load()
        let retainedSource = try Data(contentsOf: source)
        check("remove_deletes_only_app_snapshot", model.skills.isEmpty && removedSnapshot.skills.isEmpty && retainedSource == sourceBytes && FileManager.default.fileExists(atPath: ignoredScript.path))

        let literal = try markdown("literal", "---\nname: literal\ndescription: |\n  First line.\n  Second line.\n\n  Final line.\n---\n# Body\nKeep this text.\n")
        model.importSkill(at: literal.deletingLastPathComponent())
        check("folder_import_reads_only_direct_skill_file", model.skills.count == 1 && model.skills.first?.name == "literal")
        check("literal_description_preserves_line_breaks", model.skills.first?.summary == "First line.\nSecond line.\n\nFinal line.")
        let folded = try TextSkillImporter.parse("---\nname: folded\ndescription: >- # fold paragraphs\n  First line\n  second line\n---\nBody.", fallbackName: "unused")
        check("folded_description_joins_lines", folded.summary == "First line second line")
        let plain = try TextSkillImporter.parse("---\nname: plain # comment\ndescription: text with: colon\n  continued text\n---\nBody.", fallbackName: "unused")
        check("plain_metadata_accepts_comment_colon_and_continuation", plain.name == "plain" && plain.summary == "text with: colon continued text")
        let nested = try TextSkillImporter.parse("---\nname: outer\ntools:\n  name: ignored\n  command: ignored\n---\nBody with static tool references.", fallbackName: "unused")
        check("nested_tool_metadata_does_not_replace_name", nested.name == "outer" && nested.content == "Body with static tool references.")
        let fallbackSource = try markdown("fallback-name", "# Text-only skill\nDo this in prose.")
        check("metadata_is_optional_and_uses_folder_name", try TextSkillImporter.importSkill(at: fallbackSource).name == "fallback-name")
        let CRLF = try markdown("crlf", "\u{FEFF}---\r\nname: crlf\r\ndescription: \"Line\\nTwo\"\r\n---\r\n# Heading\r\nBody.\r\n")
        let importedCRLF = try TextSkillImporter.importSkill(at: CRLF)
        check("utf8_bom_crlf_and_double_quote_escapes_supported", importedCRLF.name == "crlf" && importedCRLF.summary == "Line\nTwo" && importedCRLF.content == "# Heading\r\nBody.\r\n")
        expectFailure("unterminated_frontmatter_rejected", .invalidFrontmatter) {
            _ = try TextSkillImporter.parse("---\nname: missing\nBody", fallbackName: "unused")
        }
        expectFailure("malformed_quoted_metadata_rejected", .invalidFrontmatter) {
            _ = try TextSkillImporter.parse("---\nname: \"missing\n---\nBody", fallbackName: "unused")
        }
        expectFailure("structured_name_rejected", .invalidFrontmatter) {
            _ = try TextSkillImporter.parse("---\nname: [one, two]\n---\nBody", fallbackName: "unused")
        }
        expectFailure("duplicate_name_metadata_rejected", .invalidFrontmatter) {
            _ = try TextSkillImporter.parse("---\nname: one\nname: two\n---\nBody", fallbackName: "unused")
        }

        let empty = try markdown("empty", "---\nname: empty\n---\n \n")
        expectFailure("empty_body_rejected", .emptyContent) { _ = try TextSkillImporter.importSkill(at: empty) }
        let invalidUTF8 = try markdown("invalid-utf8", "ignored")
        try Data([0xFF, 0xFE, 0x80]).write(to: invalidUTF8)
        expectFailure("non_utf8_rejected", .nonUTF8) { _ = try TextSkillImporter.importSkill(at: invalidUTF8) }
        let oversizedImport = try markdown("oversized-import", String(repeating: "x", count: TextSkillImporter.maximumImportBytes + 1))
        expectFailure("oversized_import_rejected", .importTooLarge) { _ = try TextSkillImporter.importSkill(at: oversizedImport) }
        let wrongName = root.appendingPathComponent("other.md")
        try Data("Body".utf8).write(to: wrongName)
        expectFailure("other_filename_rejected", .invalidSelection) { _ = try TextSkillImporter.importSkill(at: wrongName) }
        expectFailure("remote_url_rejected", .invalidSelection) { _ = try TextSkillImporter.importSkill(at: URL(string: "https://example.invalid/SKILL.md")!) }
        expectFailure("missing_skill_file_rejected", .unreadableImport) { _ = try TextSkillImporter.importSkill(at: root.appendingPathComponent("no-such-folder/SKILL.md")) }
        let linkedFolder = root.appendingPathComponent("linked-import", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedFolder, withIntermediateDirectories: true)
        let linkedSource = linkedFolder.appendingPathComponent("SKILL.md")
        try FileManager.default.createSymbolicLink(at: linkedSource, withDestinationURL: literal)
        expectFailure("symbolic_link_import_rejected", .unreadableImport) { _ = try TextSkillImporter.importSkill(at: linkedSource) }

        func validate(_ skill: TextSkill) throws { try TextSkillsSnapshot(skills: [skill]).validate() }
        try validate(.init(name: "exact", content: String(repeating: "x", count: 32_768)))
        check("exact_32k_body_allowed", true)
        expectFailure("body_utf8_bytes_enforced", .contentTooLarge) { try validate(.init(name: "large", content: String(repeating: "中", count: 10_923))) }
        expectFailure("empty_name_rejected", .invalidName) { try validate(.init(name: "", content: "Body")) }
        expectFailure("whitespace_name_rejected", .invalidName) { try validate(.init(name: " name ", content: "Body")) }
        expectFailure("control_character_name_rejected", .invalidName) { try validate(.init(name: "name\nnext", content: "Body")) }
        expectFailure("format_character_name_rejected", .invalidName) { try validate(.init(name: "name\u{200B}", content: "Body")) }
        try validate(.init(name: String(repeating: "a\u{301}", count: 40), summary: String(repeating: "a", count: 600), content: "Body"))
        check("exact_name_and_summary_limits_allowed", true)
        expectFailure("name_scalar_count_enforced", .invalidName) { try validate(.init(name: String(repeating: "a\u{301}", count: 41), content: "Body")) }
        expectFailure("summary_limit_enforced", .invalidSummary) { try validate(.init(name: "summary", summary: String(repeating: "a", count: 601), content: "Body")) }
        let canonicalA = TextSkill(name: "café", content: "Body")
        let canonicalB = TextSkill(name: "cafe\u{301}", content: "Body")
        expectFailure("canonical_equivalent_names_rejected", .duplicateName) { try TextSkillsSnapshot(skills: [canonicalA, canonicalB]).validate() }
        expectFailure("duplicate_identifier_rejected", .duplicateID) { try TextSkillsSnapshot(skills: [canonicalA, .init(id: canonicalA.id, name: "other", content: "Body")]).validate() }
        let thirtyTwo = (0..<32).map { TextSkill(name: "skill-\($0)", content: "Body") }
        try TextSkillsSnapshot(skills: thirtyTwo).validate()
        check("exact_32_saved_skills_allowed", true)
        expectFailure("saved_skill_count_limit_enforced", .tooManySkills) { try TextSkillsSnapshot(skills: thirtyTwo + [.init(name: "extra", content: "Body")]).validate() }
        let eightEnabled = (0..<8).map { TextSkill(name: "enabled-\($0)", content: "Body", isEnabled: true) }
        try TextSkillsSnapshot(skills: eightEnabled).validate()
        check("exact_8_enabled_skills_allowed", true)
        expectFailure("enabled_skill_count_limit_enforced", .tooManyEnabled) { try TextSkillsSnapshot(skills: eightEnabled + [.init(name: "extra", content: "Body", isEnabled: true)]).validate() }
        let exactContexts = [TextSkill(name: "a", content: String(repeating: "x", count: 32_767), isEnabled: true), TextSkill(name: "b", content: String(repeating: "x", count: 32_767), isEnabled: true)]
        try TextSkillsSnapshot(skills: exactContexts).validate()
        check("exact_64k_enabled_context_allowed", true)
        var tooLargeContexts = exactContexts
        tooLargeContexts[1].content.append("x")
        expectFailure("enabled_context_includes_name_bytes", .contextTooLarge) { try TextSkillsSnapshot(skills: tooLargeContexts).validate() }
        let fullStore = MemoryTextSkillStore(.init(skills: thirtyTwo))
        let fullModel = SkillsViewModel(store: fullStore)
        fullModel.importSkill(at: literal)
        check("import_limit_failure_retains_existing_list", fullModel.skills == thirtyTwo && fullStore.saveCount == 0 && fullModel.error == TextSkillFailure.tooManySkills.message)
        let togglingStore = MemoryTextSkillStore(.init(skills: eightEnabled + [.init(name: "ninth", content: "Body")]))
        let togglingModel = SkillsViewModel(store: togglingStore)
        togglingModel.setEnabled(togglingModel.skills.last!.id, enabled: true)
        check("enable_limit_failure_retains_disabled_state", togglingModel.skills.last?.isEnabled == false && togglingStore.saveCount == 0 && togglingModel.error == TextSkillFailure.tooManyEnabled.message)

        let failedStore = MemoryTextSkillStore(.init(skills: [original]))
        failedStore.saveFailure = .saveFailed
        let failedModel = SkillsViewModel(store: failedStore)
        failedModel.setEnabled(original.id, enabled: true)
        check("failed_save_does_not_enable", failedModel.skills == [original] && failedModel.error == TextSkillFailure.saveFailed.message)
        failedModel.remove(original.id)
        check("failed_save_does_not_remove", failedModel.skills == [original] && failedStore.snapshot.skills == [original])
        failedModel.importSkill(at: literal)
        check("failed_save_does_not_import", failedModel.skills == [original] && failedStore.saveCount == 0 && failedModel.status == nil)
        failedStore.saveFailure = nil
        failedModel.setEnabled(original.id, enabled: true)
        check("save_retry_commits_then_clears_error", failedModel.skills.first?.isEnabled == true && failedModel.error == nil && failedStore.saveCount == 1)
        failedModel.remove(UUID())
        check("unknown_identifier_error_is_actionable", failedModel.skills.count == 1 && failedModel.error == TextSkillFailure.unknownSkill.message)

        let saved = try store.load()
        let beforeFailure = try Data(contentsOf: fileURL)
        let failedAtomic = FileTextSkillStore(fileURL: fileURL, atomicReplace: { _, _ in throw TextSkillFailure.saveFailed })
        expectFailure("atomic_replace_failure_reported", .saveFailed) { try failedAtomic.save(.empty) }
        check("atomic_failure_preserves_prior_bytes", try Data(contentsOf: fileURL) == beforeFailure)
        check("atomic_failure_cleans_temp_file", try FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path) == ["text-skills.json"])
        check("atomic_failure_keeps_readable_snapshot", try store.load() == saved)

        func invalidStored(_ name: String, _ expected: TextSkillFailure, mutation: (inout [String: Any]) -> Void) throws {
            var payload = try JSONSerialization.jsonObject(with: beforeFailure) as! [String: Any]
            mutation(&payload)
            let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try bytes.write(to: fileURL)
            expectFailure(name + "_load", expected) { _ = try store.load() }
            expectFailure(name + "_save_blocked", expected) { try store.save(.empty) }
            check(name + "_preserves_bytes", try Data(contentsOf: fileURL) == bytes)
            try beforeFailure.write(to: fileURL)
        }
        try invalidStored("future_schema", .unsupportedVersion) { $0["schemaVersion"] = 2 }
        try invalidStored("unknown_snapshot_field", .invalidFormat) { $0["sourcePath"] = "not-allowed" }
        try invalidStored("unknown_skill_field", .invalidFormat) { payload in
            var skills = payload["skills"] as! [[String: Any]]
            skills[0]["script"] = "not-allowed"
            payload["skills"] = skills
        }
        try invalidStored("duplicate_id_file", .duplicateID) { payload in
            var skills = payload["skills"] as! [[String: Any]]
            skills.append(skills[0]); payload["skills"] = skills
        }
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: fileURL)
        expectFailure("corrupt_file_load_reported", .invalidFormat) { _ = try store.load() }
        expectFailure("corrupt_file_save_blocked", .invalidFormat) { try store.save(.empty) }
        let corruptModel = SkillsViewModel(store: store)
        check("corrupt_startup_shows_actionable_error", corruptModel.skills.isEmpty && corruptModel.error == TextSkillFailure.invalidFormat.message)
        expectFailure("corrupt_startup_context_is_blocked", .invalidFormat) { _ = try corruptModel.enabledContexts() }
        corruptModel.importSkill(at: literal)
        corruptModel.remove(original.id)
        check("corrupt_startup_mutations_leave_original_bytes", try Data(contentsOf: fileURL) == corrupt && corruptModel.skills.isEmpty && corruptModel.status == nil)
        expectFailure("corruption_after_load_blocks_context", .invalidFormat) { _ = try restarted.enabledContexts() }
        try beforeFailure.write(to: fileURL)
        try Data(repeating: 32, count: FileTextSkillStore.maximumBytes + 1).write(to: fileURL)
        expectFailure("oversized_saved_file_rejected", .fileTooLarge) { _ = try store.load() }
        expectFailure("oversized_saved_file_preserved", .fileTooLarge) { try store.save(.empty) }
        try beforeFailure.write(to: fileURL)
        let directoryStore = FileTextSkillStore(fileURL: fileURL.deletingLastPathComponent())
        expectFailure("directory_destination_rejected", .readFailed) { _ = try directoryStore.load() }
        let linkedJSON = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: linkedJSON, withDestinationURL: fileURL)
        let linkedStore = FileTextSkillStore(fileURL: linkedJSON)
        expectFailure("symlink_persistence_rejected", .readFailed) { try linkedStore.save(.empty) }
        check("symlink_target_kept", try Data(contentsOf: fileURL) == beforeFailure)
        try FileManager.default.removeItem(at: root)
        check("temporary_test_directory_removed", !FileManager.default.fileExists(atPath: root.path))
    } catch {
        check("setup_or_operation_failure", false)
        if FileManager.default.fileExists(atPath: root.path) {
            do { try FileManager.default.removeItem(at: root) }
            catch { check("failed_test_cleanup", false) }
        }
    }
    return results
}
