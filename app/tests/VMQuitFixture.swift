import AppKit
import CryptoKit
import Darwin
import Foundation

// This startup-only type lives in production main.swift. The standalone target
// excludes that entrypoint, so provide its inert definition for compiled checks.
struct UnavailableTranslationProvider: TranslationProviding {
    func translate(_ request: TranslationRequest) async throws -> TranslationReply {
        throw TranslationFailure.code("TRANSLATION_BRIDGE_MISSING")
    }
}

private struct VMQuitTranslator: TranslationProviding {
    func translate(_ request: TranslationRequest) async throws -> TranslationReply {
        let text = "VM_QUIT_OFFLINE_PROMPT"
        return .init(ok: true, request_id: UUID().uuidString, original: request.text, translated: text,
                     revision: 1, translation_sha256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
                     requires_confirmation: request.operation == "translate_input", error_code: nil, fixture_only: false)
    }
}

@MainActor
private final class VMQuitHarness {
    private let delegate = ClaudeIsolationApplicationDelegate()
    private let configuration: AppConfiguration
    private let markerURL: URL
    private let resultURL: URL
    private let defaults: UserDefaults
    private let suite: String
    private let store: MemoryConversationStore
    private let translation: TranslationViewModel
    private let execution: ExecutionViewModel
    private let chat: ConversationViewModel
    private let coordinator: ApplicationTerminationCoordinator
    private let selectedID: UUID
    private let began = ContinuousClock.now
    private var quitBegan: ContinuousClock.Instant?
    private var observer: NSObjectProtocol?
    private var startupTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var actualStartedObserved = false
    private var appKitQuitRequested = false
    private var returnedWhileOwnedWorkerActive = false
    private var failureCode: String?
    private var finalized = false
    private let fakeKey = "sk-HOST-ONLY-INERT-APPKIT-VM-QUIT-FIXTURE"
    private let fakeTranslationKey = "sk-TRANSLATION-ONLY-INERT-APPKIT-VM-QUIT-FIXTURE"

    init(configuration: AppConfiguration, markerURL: URL, resultURL: URL) throws {
        self.configuration = configuration; self.markerURL = markerURL; self.resultURL = resultURL
        suite = "com.claude-isolation-poc.appkit-vm-quit.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw NSError(domain: "VMQuitFixture", code: 1) }
        self.defaults = defaults
        let translator = VMQuitTranslator()
        let translationCredentials = MemoryAppCredentialStore(fakeTranslationKey)
        let executionCredentials = MemoryAppCredentialStore(fakeKey)
        let subscriptionCredentials = MemoryAppCredentialStore("sk-ant-oat01-APPKIT-INERT-QUIT-FIXTURE", scope: .subscription)
        let translation = TranslationViewModel(provider: translator, configurationStore: .init(defaults: defaults), credentials: translationCredentials)
        translation.apiKey = fakeTranslationKey
        let execution = ExecutionViewModel(store: .init(defaults: defaults), credentials: executionCredentials, subscriptionCredentials: subscriptionCredentials)
        execution.apiKey = fakeKey; execution.modelName = "deepseek-flash[1m]"
        execution.subscriptionToken = "sk-ant-oat01-APPKIT-INERT-QUIT-FIXTURE"
        let record = ConversationRecord(title: "AppKit VM quit fixture", draft: "Current offline quit fixture", messages: [
            .init(role: .user, text: "EARLIER_APPKIT_FIXTURE_QUESTION"),
            .init(role: .assistant, text: "EARLIER_APPKIT_FIXTURE_ANSWER", translation: "Retained offline translation")
        ])
        selectedID = record.id
        let store = MemoryConversationStore(.init(selectedID: record.id, conversations: [record]))
        let provider = StdioChatProvider(configuration: configuration,
            networkPolicyProvider: FixedNetworkPolicyProvider(), runtimeProfileProvider: FixedRuntimeProfileProvider())
        let chat = ConversationViewModel(translation: translation, execution: execution, translator: translator, provider: provider,
            store: store, translationCredentials: translationCredentials, executionCredentials: executionCredentials,
            subscriptionCredentials: subscriptionCredentials)
        let coordinator = ApplicationTerminationCoordinator(chat: chat, execution: execution, translation: translation)
        self.translation = translation; self.execution = execution; self.store = store; self.chat = chat; self.coordinator = coordinator
        delegate.terminationCoordinator = coordinator
        delegate.terminationFailure = { [weak self] _ in
            guard let self else { return }
            self.failureCode = "TERMINATION_COORDINATOR_FAILED"
            self.finalize(willTerminateObserved: false)
            Darwin.exit(1)
        }
    }

    func start() {
        print("VM_QUIT_FIXTURE_APPKIT_RUN_STARTED"); fflush(stdout)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: app, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.finalize(willTerminateObserved: true)
                    if self.failureCode != nil { Darwin.exit(1) }
                }
            }
        startupTask = Task { @MainActor in
            print("VM_QUIT_FIXTURE_CHAT_START_REQUESTED"); fflush(stdout)
            self.chat.send()
            let deadline = ContinuousClock.now.advanced(by: .seconds(34))
            while ContinuousClock.now < deadline {
                let marker = self.marker()
                if marker["native_init_observed"] as? Bool == true && marker["transport_entered"] as? Bool == true &&
                    self.chat.activityStatus == "模型正在回复…" && OwnedProcessRegistry.shared.activeCount == 1 {
                    self.actualStartedObserved = true
                    self.requestActualAppKitQuit()
                    return
                }
                if !self.chat.isBusy { self.failureCode = "CHAT_ENDED_BEFORE_ACTIVE_VM"; self.requestActualAppKitQuit(); return }
                do { try await Task.sleep(for: .milliseconds(20)) }
                catch { return }
            }
            self.failureCode = "VM_STARTUP_TIMED_OUT"
            self.requestActualAppKitQuit()
        }
        watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(36)) } catch { return }
            self.failureCode = "OVERALL_TEST_TIMED_OUT"
            if !self.appKitQuitRequested { self.requestActualAppKitQuit() }
        }
        app.run()
        if !finalized { failureCode = "APPKIT_RUN_RETURNED_WITHOUT_TERMINATION"; finalize(willTerminateObserved: false) }
    }

    private func requestActualAppKitQuit() {
        guard !appKitQuitRequested else { return }
        appKitQuitRequested = true; quitBegan = ContinuousClock.now
        print("VM_QUIT_FIXTURE_APPKIT_QUIT_REQUESTED"); fflush(stdout)
        NSApplication.shared.terminate(nil)
        // The production delegate intercepts this attempt while an owned worker
        // exists, then retries actual AppKit termination after real drain.
        returnedWhileOwnedWorkerActive = OwnedProcessRegistry.shared.activeCount > 0 && !coordinator.isReadyToTerminate
    }

    private func marker() -> [String: Any] {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return [:] }
        do {
            guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any] else {
                failureCode = "VM_MARKER_SCHEMA_INVALID"; return [:]
            }
            return value
        } catch { failureCode = "VM_MARKER_READ_FAILED"; return [:] }
    }

    private func finalize(willTerminateObserved: Bool) {
        guard !finalized else { return }
        finalized = true; watchdog?.cancel(); startupTask?.cancel()
        let receipt = marker()
        let workerDrained = OwnedProcessRegistry.shared.activeCount == 0
        let vmStopped = receipt["vm_stopped_observed"] as? Bool == true && receipt["vm_cleanup_complete"] as? Bool == true
        let childClosed = receipt["python_child_closed"] as? Bool == true && receipt["python_child_signal"] is NSNull
        let pythonPID = (receipt["python_child_pid"] as? NSNumber)?.int32Value
        let pythonExited = pythonPID.map { Darwin.kill($0, 0) != 0 && errno == ESRCH } ?? false
        let historyRetained = chat.selectedID == selectedID && chat.conversations.count == 1 &&
            chat.draft == "Current offline quit fixture" && chat.messages.first?.text == "EARLIER_APPKIT_FIXTURE_QUESTION" &&
            chat.messages.dropFirst().first?.translation == "Retained offline translation" &&
            store.snapshot.conversations == chat.conversations && store.snapshot.selectedID == selectedID
        let memoryCredentialsRetained = execution.apiKey == fakeKey && translation.apiKey == fakeTranslationKey &&
            execution.subscriptionToken == "sk-ant-oat01-APPKIT-INERT-QUIT-FIXTURE"
        let requirements: [(String, Bool)] = [
            ("actual_appkit_termination_notification", willTerminateObserved),
            ("actual_guest_sdk_native_init_before_quit", actualStartedObserved),
            ("actual_appkit_quit_intercepted_with_owned_worker", returnedWhileOwnedWorkerActive),
            ("production_termination_coordinator_ready", coordinator.isReadyToTerminate),
            ("owned_process_registry_drained", workerDrained),
            ("vm_stopped_and_cleanup_receipt", vmStopped),
            ("python_child_closed_and_exited", childClosed && pythonExited),
            ("node_received_termination_signal", receipt["sigterm_observed"] as? Bool == true),
            ("host_sdk_imports_forbidden_and_absent", receipt["host_sdk_import_attempts"] as? Int == 0),
            ("host_key_absent_from_guest_frames", receipt["host_key_absent_from_guest_frames"] as? Bool == true),
            ("old_history_absent_from_guest_frames", receipt["old_history_absent_from_guest_frames"] as? Bool == true),
            ("memory_history_selection_draft_retained", historyRetained),
            ("memory_credentials_retained", memoryCredentialsRetained)
        ]
        let failed = requirements.filter { !$0.1 }.map(\.0)
        if !failed.isEmpty && failureCode == nil { failureCode = "QUIT_REQUIREMENT_FAILED" }
        let elapsed = began.duration(to: .now), quitElapsed = quitBegan?.duration(to: .now)
        func seconds(_ value: Duration) -> Double {
            Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
        }
        let result: [String: Any] = [
            "schema": "appkit-native-vm-quit-fixture/v1", "status": failureCode == nil ? "passed" : "failed",
            "scope": "standalone_appkit_harness_using_production_swift_lifecycle_and_bundled_vm_runtime",
            "formal_user_app_launched": false, "appkit_terminate_called": appKitQuitRequested,
            "production_delegate_async_retry_used": true, "checks": Dictionary(uniqueKeysWithValues: requirements),
            "failures": failed, "failure_code": failureCode as Any? ?? NSNull(),
            "duration_seconds": seconds(elapsed), "quit_duration_seconds": quitElapsed.map(seconds) as Any? ?? NSNull(),
            "registry_active_at_termination": OwnedProcessRegistry.shared.activeCount,
            "real_credentials_read": false, "real_provider_calls": false, "keychain_accessed": false,
            "production_history_read": false, "fixture_credentials_memory_only": true,
            "vm_receipt": receipt
        ]
        defaults.removePersistentDomain(forName: suite)
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: resultURL, options: .atomic)
            print(String(decoding: data, as: UTF8.self)); fflush(stdout)
        } catch { fputs("VM_QUIT_FIXTURE_EVIDENCE_WRITE_FAILED\n", stderr); failureCode = "EVIDENCE_WRITE_FAILED" }
    }
}

@main
@MainActor
private struct VMQuitFixtureMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 5, arguments[1] == "--fixture-config" else {
            fputs("VM_QUIT_FIXTURE_ARGUMENTS_REQUIRED\n", stderr); Darwin.exit(2)
        }
        do {
            let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
            let harness = try VMQuitHarness(configuration: configuration, markerURL: URL(fileURLWithPath: arguments[3]),
                resultURL: URL(fileURLWithPath: arguments[4]))
            // Keep the harness alive until AppKit's actual termination path exits.
            withExtendedLifetime(harness) { harness.start() }
            Darwin.exit(1)
        } catch { fputs("VM_QUIT_FIXTURE_SETUP_FAILED\n", stderr); Darwin.exit(2) }
    }
}
