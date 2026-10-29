import Foundation

/// Only isolated preferences and memory models are used; never reads standard defaults.
@MainActor
func diagnosticsSettingsChecks() -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ value: Bool) { checks.append(("diagnostics_settings_" + name, value)) }
    let memory = DiagnosticsSettingsModel()
    check("memory_defaults_to_summary", !memory.captureBodies && memory.error == nil)
    memory.setCaptureBodies(true)
    check("memory_opt_in_is_explicit", memory.captureBodies && memory.error == nil)
    check("memory_does_not_change_other_instances", !DiagnosticsSettingsModel().captureBodies)
    let suite = "com.claude-isolation-poc.diagnostics-tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        check("isolated_preferences_available", false)
        return checks
    }
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = DiagnosticsSettingsModel(defaults: defaults)
    check("missing_preferences_are_read_only_summary", !model.captureBodies && defaults.object(forKey: DiagnosticsSettingsModel.storageKey) == nil)
    model.setCaptureBodies(true)
    check("opt_in_persists_and_reads_back", model.captureBodies && model.error == nil && DiagnosticsSettingsModel(defaults: defaults).captureBodies)
    check("preferences_contain_only_boolean", defaults.persistentDomain(forName: suite)?.keys.sorted() == [DiagnosticsSettingsModel.storageKey])
    model.setCaptureBodies(false)
    check("opt_out_persists", !model.captureBodies && !DiagnosticsSettingsModel(defaults: defaults).captureBodies)
    for invalid: Any in ["true", 1, ["capture": true]] {
        defaults.set(invalid, forKey: DiagnosticsSettingsModel.storageKey)
        let invalidModel = DiagnosticsSettingsModel(defaults: defaults)
        check("invalid_preferences_fail_closed_\(checks.count)", !invalidModel.captureBodies && invalidModel.error != nil)
    }
    let repaired = DiagnosticsSettingsModel(defaults: defaults)
    repaired.setCaptureBodies(false)
    check("explicit_setting_repairs_invalid_preferences", !repaired.captureBodies && repaired.error == nil && DiagnosticsSettingsModel(defaults: defaults).error == nil)

    let captureTime = Date(timeIntervalSince1970: 1_000_000)
    let raw = requestTraceFixture(runID: UUID(), phase: .response)
    let retained = raw.persisted(captureBody: true, capturedAt: captureTime)
    let export = RequestDiagnosticExportModel(trace: retained, now: captureTime)
    check("export_defaults_to_summary", !export.includeBody && !export.preview.contains("你好 🌏"))
    export.setIncludeBody(true, now: captureTime)
    do {
        let exportText = try export.contentForExport(now: captureTime)
        check("explicit_body_preview_is_exact_copy_source", export.includeBody && export.preview.contains("你好 🌏") && exportText == export.preview)
        do {
            _ = try export.contentForExport(now: captureTime.addingTimeInterval(ChatRequestTrace.bodyRetention))
            check("expired_body_cannot_be_exported", false)
        } catch {
            check("expired_body_cannot_be_exported", !export.includeBody && !export.preview.contains("你好 🌏") && export.notice != nil)
        }
        let legacy = RequestDiagnosticExportModel(trace: raw, now: captureTime)
        legacy.setIncludeBody(true, now: captureTime.addingTimeInterval(10 * ChatRequestTrace.bodyRetention))
        check("legacy_body_not_expired_implicitly", legacy.includeBody && legacy.preview.contains("你好 🌏"))
        legacy.updateTrace(raw.removingBody(), now: captureTime)
        check("manual_clear_replaces_open_preview_with_summary", !legacy.includeBody && !legacy.canIncludeBody && !legacy.preview.contains("你好 🌏"))
    } catch { check("export_preview_fixture", false) }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-export-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent("preview.txt")
        let preview = "offline diagnostic preview\n中文"
        try saveRequestDiagnosticPreview(preview, to: destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        check("saved_preview_matches_with_private_permissions", try String(contentsOf: destination, encoding: .utf8) == preview && (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try saveRequestDiagnosticPreview("replacement summary", to: destination)
        check("replacement_has_no_temporary_copies", try String(contentsOf: destination, encoding: .utf8) == "replacement summary" && FileManager.default.contentsOfDirectory(atPath: directory.path) == ["preview.txt"])
    } catch { check("save_preview_fixture", false) }
    do { try FileManager.default.removeItem(at: directory) }
    catch { check("export_fixture_cleanup", false) }
    return checks
}
