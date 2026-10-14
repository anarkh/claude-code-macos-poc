import Foundation
import Darwin
import Virtualization

@MainActor
func browserRuntimeLifecycleChecks() async -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ value: Bool) { checks.append(("browser_" + name, value)) }
    var complete = BrowserSerialMarkers()
    check("serial_ready_fragment_waits_newline", complete.consume(Data("BROWSER_SESSION_RE".utf8)).isEmpty && !complete.wasReady)
    check("serial_ready_fragment_completed", complete.consume(Data("ADY\r\nBROWSER_SESSION_STOP_COM".utf8)) == [.ready] && complete.wasReady)
    check("serial_stop_complete_fragment_completed", complete.consume(Data("PLETE\n".utf8)) == [.stopComplete] && complete.saveFailure(forced: false) == nil)
    _ = complete.consume(Data("BROWSER_SESSION_STOP_FAILED\nBROWSER_SESSION_STOP_ERROR=unknown-sensitive-input\n".utf8))
    check("serial_failed_after_complete_vetoes_save", complete.saveFailure(forced: false) != nil && complete.stopFailed)
    _ = complete.consume(Data("BROWSER_SESSION_STOP_COMPLETE\n".utf8))
    check("serial_complete_cannot_clear_failed", complete.saveFailure(forced: false) != nil)
    check("serial_diagnostics_not_exposed", complete.saveFailure(forced: false)?.contains("unknown-sensitive-input") == false)
    check("serial_forced_stop_uses_existing_risk_confirmation", complete.saveFailure(forced: true) == nil)
    var missing = BrowserSerialMarkers()
    check("serial_not_ready_needs_no_checkpoint", missing.saveFailure(forced: false) == nil)
    _ = missing.consume(Data("BROWSER_SESSION_READY\n".utf8))
    check("serial_ready_missing_completion_denies_save", missing.saveFailure(forced: false) != nil)
    _ = missing.consume(Data("prefix BROWSER_SESSION_STOP_COMPLETE\nBROWSER_SESSION_STOP_FAILED:detail\nBROWSER_SESSION_STOP_COM\rPLETE\n".utf8))
    check("serial_rejects_prefixed_and_diagnostic_markers", !missing.stopComplete && !missing.stopFailed)
    _ = missing.consume(Data((String(repeating: "x", count: 129) + "BROWSER_SESSION_STOP_COMPLETE\nBROWSER_SESSION_STOP_COMPLETE\n").utf8))
    check("serial_discards_overlong_lines_and_recovers", missing.stopComplete && missing.saveFailure(forced: false) == nil)
    _ = missing.consume(Data("BROWSER_SESSION_READY\n".utf8))
    check("serial_new_ready_invalidates_previous_checkpoint", missing.saveFailure(forced: false) != nil)
    _ = missing.consume(Data("BROWSER_SESSION_STOP_COMPLETE\n".utf8))
    missing.invalidateStopConfirmation()
    check("serial_read_failure_vetoes_completion", missing.saveFailure(forced: false) != nil)
    let suite = "com.claude-isolation-poc.browser-checks.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return [("browser_fixture_defaults", false)] }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("browser-lifecycle-\(UUID().uuidString)")
    defer {
        defaults.removePersistentDomain(forName: suite)
        do {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        } catch { check("fixture_cleanup", false) }
    }
    let store = BrowserSettingsStore(defaults: defaults)
    do {
        check("dedicated_default_proxy", try store.load() == .defaultConfiguration)
        defaults.set(Data("CLI network settings remain separate".utf8), forKey: "claude-code.app-network-policy.v1")
        let cliBefore = defaults.data(forKey: "claude-code.app-network-policy.v1")
        let configured = BrowserSettingsConfiguration(proxyURL: "http://127.0.0.1:17898", resistFingerprinting: true)
        try store.save(configured)
        check("settings_readback", try store.load() == configured)
        check("cli_network_unchanged", defaults.data(forKey: "claude-code.app-network-policy.v1") == cliBefore)
        for invalid in ["http://localhost:17897", "http://127.0.0.1:0", "http://127.0.0.1:65536", "http://127.0.0.1:017897", "http://127.0.0.1:17897/", "https://127.0.0.1:17897", "http://user@127.0.0.1:17897", "http://127.0.0.1:17897?direct=true", "http://10.0.0.1:17897"] {
            do { try store.save(.init(proxyURL: invalid)); check("reject_invalid_proxy", false) }
            catch { check("reject_invalid_proxy", true) }
        }
        check("invalid_save_preserves_existing", try store.load() == configured)
        let storage = BrowserRuntimeStorage(bundleResourcesURL: directory.appendingPathComponent("missing-resources"),
                                           profileDirectoryURL: directory.appendingPathComponent("Browser"))
        let controller = BrowserVMController(storage: storage, settingsStore: store)
        var clipboardReads = 0
        check("clipboard_idle_does_not_read", clipboardReads == 0 && !controller.canPasteText)
        controller.pasteTextFromMac { clipboardReads += 1; return "fixture-only" }
        check("clipboard_stopped_paste_does_not_read", clipboardReads == 0 && controller.pasteStatus != nil)
        check("configuration_restored", controller.resistFingerprinting && controller.proxyURL == configured.proxyURL)
        controller.beginTermination()
        controller.pasteTextFromMac { clipboardReads += 1; return "fixture-only" }
        check("clipboard_terminating_paste_does_not_read", clipboardReads == 0 && !controller.canPasteText)
        check("quit_closes_start_admission", !controller.canStart && controller.isTerminationWorkSettled)
        controller.endTermination()
        check("failed_quit_restores_admission", controller.canStart && controller.canConfigure)
        if VZVirtualMachine.isSupported {
            // The resources directory does not exist, so this cannot create a VM.
            controller.start()
            controller.beginTermination()
            for _ in 0..<300 where !controller.isTerminationWorkSettled {
                try await Task.sleep(for: .milliseconds(10))
            }
            check("quit_during_prepare_settles", controller.isTerminationWorkSettled && controller.virtualMachine == nil)
            check("quit_during_prepare_keeps_admission_closed", !controller.canStart)
            controller.endTermination()
        }
        defaults.set(Data("invalid settings".utf8), forKey: BrowserSettingsStore.storageKey)
        let malformed = BrowserVMController(storage: storage, settingsStore: store)
        check("invalid_settings_fail_closed", !malformed.canStart && malformed.error != nil)
        malformed.proxyDraft = "http://127.0.0.1:17897"; malformed.saveSettings()
        check("explicit_save_recovers_settings", malformed.canStart && malformed.error == nil)
        let fixture = BrowserVMController(storage: storage, settingsStore: store, fixtureOnly: true)
        check("ui_fixture_never_starts_vm", !fixture.canStart && fixture.virtualMachine == nil)
        func waitForStop(_ controller: BrowserVMController) async throws {
            for _ in 0..<100 where !controller.isTerminationWorkSettled {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let delayed = Pipe()
        let delayedDescriptor = dup(delayed.fileHandleForWriting.fileDescriptor)
        guard delayedDescriptor >= 0 else { throw BrowserRuntimeFailure.channel }
        let delayedWriter = FileHandle(fileDescriptor: delayedDescriptor, closeOnDealloc: true)
        try delayed.fileHandleForWriting.write(contentsOf: Data("BROWSER_SESSION_READY\n".utf8))
        try fixture.finishStoppedFixture(serial: delayed)
        check("stop_before_serial_completion_keeps_drain_pending", !fixture.isTerminationWorkSettled && !fixture.canConfigure)
        do { try fixture.acknowledgeTerminationSaveFailure(); check("stop_pending_acknowledgement_denied", false) }
        catch { check("stop_pending_acknowledgement_denied", true) }
        try await Task.sleep(for: .milliseconds(20))
        try delayedWriter.write(contentsOf: Data("BROWSER_SESSION_STOP_COMPLETE\n".utf8)); try delayedWriter.close()
        try await waitForStop(fixture)
        check("stop_late_complete_and_eof_confirms_save", fixture.isTerminationWorkSettled && fixture.terminationSaveFailure == nil && fixture.error == nil)
        let unconfirmed = Pipe()
        try unconfirmed.fileHandleForWriting.write(contentsOf: Data("BROWSER_SESSION_READY\n".utf8))
        try fixture.finishStoppedFixture(serial: unconfirmed)
        check("stop_eof_without_checkpoint_preserves_warning", fixture.isTerminationWorkSettled && fixture.terminationSaveFailure != nil && fixture.error == fixture.terminationSaveFailure)
        fixture.saveSettings()
        check("stop_settings_do_not_clear_save_warning", fixture.error == fixture.terminationSaveFailure)
        try fixture.acknowledgeTerminationSaveFailure()
        check("stop_settled_explicit_acknowledgement_keeps_display_warning", fixture.terminationSaveFailure == nil && fixture.error != nil)
        let conflicting = Pipe()
        let conflictingDescriptor = dup(conflicting.fileHandleForWriting.fileDescriptor)
        guard conflictingDescriptor >= 0 else { throw BrowserRuntimeFailure.channel }
        let conflictingWriter = FileHandle(fileDescriptor: conflictingDescriptor, closeOnDealloc: true)
        try conflicting.fileHandleForWriting.write(contentsOf: Data("BROWSER_SESSION_READY\nBROWSER_SESSION_STOP_COMPLETE\n".utf8))
        try fixture.finishStoppedFixture(serial: conflicting)
        try await Task.sleep(for: .milliseconds(20))
        try conflictingWriter.write(contentsOf: Data("BROWSER_SESSION_STOP_FAILED\n".utf8)); try conflictingWriter.close()
        try await waitForStop(fixture)
        check("stop_late_failed_vetoes_earlier_completion", fixture.isTerminationWorkSettled && fixture.terminationSaveFailure != nil)
        let noEOF = Pipe()
        let noEOFDescriptor = dup(noEOF.fileHandleForWriting.fileDescriptor)
        guard noEOFDescriptor >= 0 else { throw BrowserRuntimeFailure.channel }
        let noEOFWriter = FileHandle(fileDescriptor: noEOFDescriptor, closeOnDealloc: true)
        try noEOF.fileHandleForWriting.write(contentsOf: Data("BROWSER_SESSION_READY\nBROWSER_SESSION_STOP_COMPLETE\n".utf8))
        try fixture.finishStoppedFixture(serial: noEOF)
        try await waitForStop(fixture)
        try noEOFWriter.close()
        check("stop_bounded_drain_without_eof_denies_save", fixture.isTerminationWorkSettled && fixture.terminationSaveFailure != nil)
        let forced = Pipe()
        try forced.fileHandleForWriting.write(contentsOf: Data("BROWSER_SESSION_READY\n".utf8))
        try fixture.finishStoppedFixture(serial: forced, forced: true)
        check("stop_forced_keeps_risk_warning_without_second_save_gate", fixture.isTerminationWorkSettled && fixture.terminationSaveFailure == nil && fixture.error?.contains("强制停止") == true)
        check("no_profile_created_by_settings", !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Browser/profile.raw").path))
    } catch { check("unexpected_error", false) }
    return checks
}
