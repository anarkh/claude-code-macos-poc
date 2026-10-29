import AppKit
import Darwin
import Foundation
import SwiftUI

struct UnavailableTranslationProvider: TranslationProviding {
    func translate(_ request: TranslationRequest) async throws -> TranslationReply {
        throw TranslationFailure.code("TRANSLATION_BRIDGE_MISSING")
    }
}

struct ClaudeIsolationApplication: App {
    @NSApplicationDelegateAdaptor(ClaudeIsolationApplicationDelegate.self) private var applicationDelegate
    private let terminationCoordinator: ApplicationTerminationCoordinator
    private let configuration: AppConfiguration?
    @StateObject private var model: TranslationViewModel
    @StateObject private var execution: ExecutionViewModel
    @StateObject private var chat: ConversationViewModel
    @StateObject private var skills: SkillsViewModel
    @StateObject private var network: NetworkSettingsViewModel
    @StateObject private var runtime: RuntimeSettingsViewModel
    @StateObject private var loginReset: ClaudeLoginResetModel
    @StateObject private var runtimeVersion: RuntimeVersionViewModel
    @StateObject private var browser: BrowserVMController
    @StateObject private var diagnostics: DiagnosticsSettingsModel
    @StateObject private var deviceIdentity: DeviceIdentitySettingsModel
    init() {
        let fixtureOnly = CommandLine.arguments.contains("--ui-fixture")
        let testingUI = fixtureOnly || CommandLine.arguments.contains("--smoke-test")
        let diagnostics = DiagnosticsSettingsModel(defaults: testingUI ? nil : UserDefaults.standard)
        _diagnostics = StateObject(wrappedValue: diagnostics)
        // UI fixtures must never scan the user's HOME or real run directories.
        let resetFixtureRoot: URL?
        if testingUI {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-reset-ui-\(UUID().uuidString)")
            do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            catch { fatalError("Unable to create isolated reset fixture directory") }
            guard let physical = realpath(root.path, nil) else { fatalError("Unable to resolve reset fixture directory") }
            resetFixtureRoot = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            free(physical)
        } else { resetFixtureRoot = nil }
        let identityStore = FileInstallationIdentityStore(directoryURL:
            resetFixtureRoot?.appendingPathComponent("Identity", isDirectory: true)
                ?? FileInstallationIdentityStore.defaultDirectoryURL)
        _deviceIdentity = StateObject(wrappedValue: DeviceIdentitySettingsModel(store: identityStore))
        let executionConfigurationStore: ExecutionConfigurationStore
        let translationConfigurationStore: TranslationConfigurationStore
        let browserSettingsStore: BrowserSettingsStore
        if testingUI {
            guard let fixtureDefaults = UserDefaults(suiteName: "com.claude-isolation-poc.ui-fixture.\(UUID().uuidString)") else {
                fatalError("Unable to create isolated UI fixture preferences")
            }
            executionConfigurationStore = ExecutionConfigurationStore(defaults: fixtureDefaults)
            translationConfigurationStore = TranslationConfigurationStore(defaults: fixtureDefaults)
            browserSettingsStore = BrowserSettingsStore(defaults: fixtureDefaults)
        } else {
            executionConfigurationStore = ExecutionConfigurationStore()
            translationConfigurationStore = TranslationConfigurationStore()
            browserSettingsStore = BrowserSettingsStore()
        }
        let networkStore: any NetworkConfigurationPersisting = testingUI ? MemoryNetworkConfigurationStore() : NetworkConfigurationStore()
        _network = StateObject(wrappedValue: NetworkSettingsViewModel(store: networkStore))
        let runtimeStore: any RuntimeProfilePersisting = testingUI ? MemoryRuntimeProfileStore() : RuntimeProfileStore()
        _runtime = StateObject(wrappedValue: RuntimeSettingsViewModel(store: runtimeStore))
        let translationCredentials: any AppCredentialStoring
        let executionCredentials: any AppCredentialStoring
        let subscriptionCredentials: any AppCredentialStoring
        if testingUI {
            translationCredentials = MemoryAppCredentialStore()
            executionCredentials = MemoryAppCredentialStore()
            subscriptionCredentials = MemoryAppCredentialStore(scope: .subscription)
        } else {
            translationCredentials = FileCredentialStore(scope: .translation)
            executionCredentials = FileCredentialStore(scope: .execution)
            subscriptionCredentials = FileCredentialStore(scope: .subscription)
        }
        let subscriptionAccountStore: any SubscriptionAccountStoring
        if testingUI {
            subscriptionAccountStore = MemorySubscriptionAccountStore()
        } else {
            subscriptionAccountStore = FileSubscriptionAccountStore(legacyCredentials: subscriptionCredentials)
        }
        let skillStore: any TextSkillPersisting
        if testingUI { skillStore = MemoryTextSkillStore() }
        else { skillStore = FileTextSkillStore() }
        let skills = SkillsViewModel(store: skillStore)
        _skills = StateObject(wrappedValue: skills)
        let packageStore: any RuntimePackageManaging
        if let resetFixtureRoot {
            packageStore = RuntimePackageStore(bundleContents: Bundle.main.bundleURL.appendingPathComponent("Contents"),
                storageRoot: resetFixtureRoot.appendingPathComponent("RuntimePackages"))
        } else { packageStore = RuntimePackageEnvironment.store }
        let updateConfigurationStore: any RuntimeUpdateConfigurationPersisting = testingUI
            ? MemoryRuntimeUpdateConfigurationStore() : RuntimeUpdateConfigurationStore()
        do {
            let loaded = try AppConfiguration.load()
            let configuration = testingUI ? AppConfiguration(projectRoot: loaded.projectRoot, nodeExecutable: loaded.nodeExecutable) : loaded
            self.configuration = configuration
            let browser = BrowserVMController(storage: BrowserRuntimeStorage(
                developmentProjectRoot: configuration.projectRoot,
                profileDirectoryURL: resetFixtureRoot?.appendingPathComponent("Browser") ?? BrowserRuntimeStorage.defaultDirectoryURL),
                settingsStore: browserSettingsStore, fixtureOnly: testingUI)
            _browser = StateObject(wrappedValue: browser)
            let quotaService: any SubscriptionQuotaFetching = testingUI
                ? FixtureSubscriptionQuotaService() : StdioSubscriptionQuotaService(configuration: configuration)
            let accounts = SubscriptionAccountsModel(store: subscriptionAccountStore, quotaService: quotaService)
            _ = accounts.load()
            let execution = ExecutionViewModel(store: executionConfigurationStore, credentials: executionCredentials,
                subscriptionCredentials: subscriptionCredentials,
                tester: StdioExecutionConnectionTester(configuration: configuration, installationIdentityStore: identityStore),
                subscriptionAccounts: accounts)
            let translator = StdioTranslationProvider(configuration: configuration, fixtureOnly: fixtureOnly)
            let model = TranslationViewModel(provider: translator, configurationStore: translationConfigurationStore, credentials: translationCredentials)
            if fixtureOnly {
                model.apiKey = "explicit-offline-ui-fixture-key"
                execution.apiKey = "explicit-offline-ui-fixture-key"
                execution.modelName = "deepseek-flash[1m]"
            }
            let conversationStore: any ConversationPersisting
            if fixtureOnly && CommandLine.arguments.contains("--ui-layout-fixture") {
                conversationStore = conversationLayoutFixtureStore()
            } else if testingUI {
                conversationStore = MemoryConversationStore()
            } else {
                conversationStore = FileConversationStore()
            }
            let chat = ConversationViewModel(translation: model, execution: execution, translator: translator,
                provider: StdioChatProvider(configuration: configuration, fixtureOnly: fixtureOnly, installationIdentityStore: identityStore),
                store: conversationStore, translationCredentials: translationCredentials,
                executionCredentials: executionCredentials, subscriptionCredentials: subscriptionCredentials, fixtureOnly: fixtureOnly, skills: skills,
                diagnostics: diagnostics)
            _model = StateObject(wrappedValue: model)
            _execution = StateObject(wrappedValue: execution)
            _chat = StateObject(wrappedValue: chat)
            let loginReset = ClaudeLoginResetModel(chat: chat, execution: execution, translation: model,
                runtime: OwnedRuntimeCleanupService(tempRoot: resetFixtureRoot),
                externalScanner: ExternalClaudeLocationScanner(home: resetFixtureRoot ?? FileManager.default.homeDirectoryForCurrentUser))
            _loginReset = StateObject(wrappedValue: loginReset)
            let runtimeVersion = RuntimeVersionViewModel(store: packageStore, isApplicationIdle: {
                chat.isTerminationWorkSettled && execution.isTerminationWorkSettled && model.isTerminationWorkSettled && !loginReset.isBusy
            }, updater: testingUI ? nil : StdioRuntimeUpdateService(configuration: configuration,
                bundleContents: Bundle.main.bundleURL.appendingPathComponent("Contents")),
                officialUpdater: testingUI ? nil : StdioOfficialRuntimeUpdateService(configuration: configuration,
                    bundleContents: Bundle.main.bundleURL.appendingPathComponent("Contents")),
                updateConfigurationStore: updateConfigurationStore)
            _runtimeVersion = StateObject(wrappedValue: runtimeVersion)
            configureAccountLifecycle(accounts, chat: chat, execution: execution, loginReset: loginReset, runtimeVersion: runtimeVersion)
            terminationCoordinator = ApplicationTerminationCoordinator(chat: chat, execution: execution,
                translation: model, loginReset: loginReset, runtimeVersions: runtimeVersion, browser: browser)
        } catch {
            configuration = nil
            let browser = BrowserVMController(storage: BrowserRuntimeStorage(
                profileDirectoryURL: resetFixtureRoot?.appendingPathComponent("Browser") ?? BrowserRuntimeStorage.defaultDirectoryURL),
                settingsStore: browserSettingsStore, fixtureOnly: testingUI)
            _browser = StateObject(wrappedValue: browser)
            let accounts = SubscriptionAccountsModel(store: subscriptionAccountStore)
            _ = accounts.load()
            let execution = ExecutionViewModel(store: executionConfigurationStore, credentials: executionCredentials,
                subscriptionCredentials: subscriptionCredentials, subscriptionAccounts: accounts)
            let model = TranslationViewModel(provider: UnavailableTranslationProvider(), configurationStore: translationConfigurationStore, credentials: translationCredentials)
            _execution = StateObject(wrappedValue: execution)
            _model = StateObject(wrappedValue: model)
            let chat = ConversationViewModel(translation: model, execution: execution,
                translator: UnavailableTranslationProvider(), provider: UnavailableChatProvider(),
                store: testingUI ? MemoryConversationStore() : FileConversationStore(),
                translationCredentials: translationCredentials, executionCredentials: executionCredentials, subscriptionCredentials: subscriptionCredentials, skills: skills,
                diagnostics: diagnostics)
            _chat = StateObject(wrappedValue: chat)
            let loginReset = ClaudeLoginResetModel(chat: chat, execution: execution, translation: model,
                runtime: OwnedRuntimeCleanupService(tempRoot: resetFixtureRoot),
                externalScanner: ExternalClaudeLocationScanner(home: resetFixtureRoot ?? FileManager.default.homeDirectoryForCurrentUser))
            _loginReset = StateObject(wrappedValue: loginReset)
            let runtimeVersion = RuntimeVersionViewModel(store: packageStore, isApplicationIdle: {
                chat.isTerminationWorkSettled && execution.isTerminationWorkSettled && model.isTerminationWorkSettled && !loginReset.isBusy
            }, updateConfigurationStore: updateConfigurationStore)
            _runtimeVersion = StateObject(wrappedValue: runtimeVersion)
            configureAccountLifecycle(accounts, chat: chat, execution: execution, loginReset: loginReset, runtimeVersion: runtimeVersion)
            terminationCoordinator = ApplicationTerminationCoordinator(chat: chat, execution: execution,
                translation: model, loginReset: loginReset, runtimeVersions: runtimeVersion, browser: browser)
        }
        applicationDelegate.terminationCoordinator = terminationCoordinator
    }
    var body: some Scene {
        WindowGroup("Claude 隔离工作台") {
            ContentView(chat: chat, browser: browser, execution: execution, configuration: configuration)
                .onAppear {
                    if CommandLine.arguments.contains("--ui-flow-test") && CommandLine.arguments.contains("--ui-fixture") {
                        Task { @MainActor in await runConversationWindowFixtureCheck(chat) }
                    }
                }
        }
            .defaultSize(width: 1280, height: 860)
            .commands { CommandGroup(replacing: .newItem) {} }
        Settings { SettingsView(model: model, execution: execution, skills: skills, network: network, runtime: runtime, loginReset: loginReset, runtimeVersion: runtimeVersion, browser: browser, diagnostics: diagnostics, chat: chat, deviceIdentity: deviceIdentity, configuration: configuration) }
    }
}

if CommandLine.arguments.contains("--configure-deepseek") {
    Task { @MainActor in
        let status = configureOfficialDeepSeek()
        fflush(stdout); exit(status)
    }
    dispatchMain()
} else if CommandLine.arguments.contains("--deepseek-live-check") {
    Task { @MainActor in
        let status = await runDeepSeekLiveCheck()
        fflush(stdout); exit(status)
    }
    dispatchMain()
} else if CommandLine.arguments.contains("--conversation-live-check") || CommandLine.arguments.contains("--conversation-fixture-check") {
    Task { @MainActor in
        let status = await runConversationLiveCheck(fixtureOnly: CommandLine.arguments.contains("--conversation-fixture-check"))
        fflush(stdout); exit(status)
    }
    dispatchMain()
} else if CommandLine.arguments.contains("--self-test") {
    Task { @MainActor in
        let status = await runSelfTests()
        fflush(stdout)
        exit(status)
    }
    dispatchMain()
} else {
    ClaudeIsolationApplication.main()
}
