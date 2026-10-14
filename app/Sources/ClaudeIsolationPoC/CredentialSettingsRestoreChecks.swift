import Foundation

private final class SettingsRestoreFixtureCredentials: AppCredentialStoring {
    var key: String?
    var loadFailure: (any Error)?
    private(set) var loads = 0, saves = 0, deletes = 0

    init(key: String? = nil) { self.key = key }
    func load() throws -> String? {
        loads += 1
        if let loadFailure { throw loadFailure }
        return key
    }
    func save(_ key: String) throws { saves += 1; self.key = key }
    func delete() throws { deletes += 1; key = nil }
}

/// Isolated public preferences, fake keys and owned temporary files only.
@MainActor
func credentialSettingsRestoreChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("credential_settings_restore_" + name, passed)) }
    let suite = "com.claude-isolation-poc.settings-restore-tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return [("credential_settings_restore_suite_available", false)] }
    defer { defaults.removePersistentDomain(forName: suite) }
    let executionStore = ExecutionConfigurationStore(defaults: defaults)
    let translationStore = TranslationConfigurationStore(defaults: defaults)
    let executionKey = "settings-restore-execution-fake-key"
    let translationKey = "settings-restore-translation-fake-key"
    let executionCredentials = SettingsRestoreFixtureCredentials(key: executionKey)
    let translationCredentials = SettingsRestoreFixtureCredentials(key: translationKey)
    let execution = ExecutionViewModel(store: executionStore, credentials: executionCredentials)
    let translation = TranslationViewModel(provider: UnavailableTranslationProvider(), configurationStore: translationStore,
                                           credentials: translationCredentials)
    check("startup_defers_both_credentials", execution.apiKey.isEmpty && translation.apiKey.isEmpty &&
          executionCredentials.loads == 0 && translationCredentials.loads == 0)
    execution.restoreSavedKeyForSettings()
    translation.restoreSavedKeyForSettings()
    check("execution_restores_saved_key_and_status", execution.apiKey == executionKey && executionCredentials.loads == 1 &&
          execution.credentialStatus == "已自动恢复本机保存的 API Key。")
    check("translation_restores_independent_key_and_status", translation.apiKey == translationKey && translationCredentials.loads == 1 &&
          translation.credentialStatus == "已自动恢复本机保存的 API Key。")
    check("opening_settings_has_no_persistence_side_effects", executionCredentials.saves == 0 && executionCredentials.deletes == 0 &&
          translationCredentials.saves == 0 && translationCredentials.deletes == 0 &&
          executionStore.load() == .missing && translationStore.load() == .missing)
    execution.restoreSavedKeyForSettings()
    translation.restoreSavedKeyForSettings()
    check("repeated_open_uses_existing_memory", executionCredentials.loads == 1 && translationCredentials.loads == 1 &&
          execution.apiKey == executionKey && translation.apiKey == translationKey)
    let draft = "settings-restore-unsaved-draft-fake-key"
    execution.apiKey = draft
    translation.apiKey = draft
    executionCredentials.loadFailure = LocalCredentialFailure.readFailed
    translationCredentials.loadFailure = LocalCredentialFailure.readFailed
    execution.restoreSavedKeyForSettings()
    translation.restoreSavedKeyForSettings()
    check("execution_unsaved_draft_is_not_overwritten_or_read", execution.apiKey == draft && executionCredentials.loads == 1 &&
          executionCredentials.key == executionKey && execution.credentialStatus == "凭据仅在本次运行内存中。")
    check("translation_unsaved_draft_is_not_overwritten_or_read", translation.apiKey == draft && translationCredentials.loads == 1 &&
          translationCredentials.key == translationKey && translation.credentialStatus == "凭据仅在本次运行内存中。")

    let missingExecutionCredentials = SettingsRestoreFixtureCredentials()
    let missingTranslationCredentials = SettingsRestoreFixtureCredentials()
    let missingExecution = ExecutionViewModel(store: executionStore, credentials: missingExecutionCredentials)
    let missingTranslation = TranslationViewModel(provider: UnavailableTranslationProvider(), configurationStore: translationStore,
                                                  credentials: missingTranslationCredentials)
    missingExecution.restoreSavedKeyForSettings()
    missingTranslation.restoreSavedKeyForSettings()
    check("missing_execution_key_has_normal_status", missingExecution.apiKey.isEmpty && missingExecution.error == nil &&
          missingExecution.credentialStatus == "本 App 尚未保存执行模型 API Key。")
    check("missing_translation_key_has_normal_status", missingTranslation.apiKey.isEmpty &&
          missingTranslation.credentialStatus == "本 App 尚未保存翻译模型 API Key。")
    missingExecutionCredentials.key = " \n "
    missingTranslationCredentials.key = " \n "
    missingExecution.restoreSavedKeyForSettings()
    missingTranslation.restoreSavedKeyForSettings()
    check("blank_loaded_values_do_not_become_credentials", missingExecution.apiKey.isEmpty && missingTranslation.apiKey.isEmpty &&
          missingExecutionCredentials.saves == 0 && missingTranslationCredentials.saves == 0)

    for (name, failure) in [("format", LocalCredentialFailure.invalidFormat), ("permissions", .readFailed)] {
        missingExecutionCredentials.loadFailure = failure
        missingTranslationCredentials.loadFailure = failure
        missingExecution.restoreSavedKeyForSettings()
        missingTranslation.restoreSavedKeyForSettings()
        check("execution_\(name)_failure_is_actionable", missingExecution.apiKey.isEmpty && missingExecution.error == nil &&
              missingExecution.credentialStatus == failure.message && missingExecutionCredentials.saves == 0 && missingExecutionCredentials.deletes == 0)
        check("translation_\(name)_failure_is_actionable", missingTranslation.apiKey.isEmpty &&
              missingTranslation.credentialStatus == failure.message && missingTranslationCredentials.saves == 0 && missingTranslationCredentials.deletes == 0)
    }
    let privateMarker = "settings-restore-private-error-" + executionKey
    let rawFailure = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: privateMarker])
    missingExecutionCredentials.loadFailure = rawFailure
    missingTranslationCredentials.loadFailure = rawFailure
    missingExecution.restoreSavedKeyForSettings()
    missingTranslation.restoreSavedKeyForSettings()
    check("execution_unknown_failure_hides_raw_error_and_key", missingExecution.apiKey.isEmpty && missingExecution.error == nil &&
          missingExecution.credentialStatus == "无法自动恢复执行模型 API Key，请检查本机凭据文件的访问权限。" &&
          !missingExecution.credentialStatus.contains(privateMarker) && !missingExecution.credentialStatus.contains(executionKey))
    check("translation_unknown_failure_hides_raw_error_and_key", missingTranslation.apiKey.isEmpty &&
          missingTranslation.credentialStatus == "无法自动恢复翻译模型 API Key，请检查本机凭据文件的访问权限。" &&
          !(missingTranslation.credentialStatus ?? "").contains(privateMarker) && !(missingTranslation.credentialStatus ?? "").contains(executionKey))
    missingExecutionCredentials.loadFailure = nil
    missingTranslationCredentials.loadFailure = nil
    missingExecutionCredentials.key = executionKey
    missingTranslationCredentials.key = translationKey
    missingExecution.restoreSavedKeyForSettings()
    missingTranslation.restoreSavedKeyForSettings()
    check("later_success_replaces_restore_failure_status", missingExecution.apiKey == executionKey && missingTranslation.apiKey == translationKey &&
          missingExecution.credentialStatus == "已自动恢复本机保存的 API Key。" && missingTranslation.credentialStatus == missingExecution.credentialStatus)

    defaults.set(Data("invalid-public-configuration".utf8), forKey: ExecutionConfigurationStore.storageKey)
    let invalidProfileCredentials = SettingsRestoreFixtureCredentials(key: executionKey)
    let invalidProfile = ExecutionViewModel(store: executionStore, credentials: invalidProfileCredentials)
    let configurationError = invalidProfile.error
    invalidProfile.restoreSavedKeyForSettings()
    check("restore_success_preserves_public_configuration_error", configurationError == ExecutionConfigurationError.invalidFormat.message &&
          invalidProfile.error == configurationError && invalidProfile.apiKey == executionKey)
    invalidProfile.apiKey = ""
    invalidProfileCredentials.key = nil
    invalidProfile.restoreSavedKeyForSettings()
    check("missing_key_preserves_public_configuration_error", invalidProfile.error == configurationError &&
          invalidProfile.credentialStatus == "本 App 尚未保存执行模型 API Key。")
    invalidProfileCredentials.loadFailure = LocalCredentialFailure.readFailed
    invalidProfile.restoreSavedKeyForSettings()
    check("restore_failure_preserves_public_configuration_error", invalidProfile.error == configurationError &&
          invalidProfile.credentialStatus == LocalCredentialFailure.readFailed.message)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-restore-files-\(UUID().uuidString)", isDirectory: true)
    let directory = root.appendingPathComponent("Credentials", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let firstExecutionStore = FileCredentialStore(scope: .execution, directoryURL: directory)
        let firstTranslationStore = FileCredentialStore(scope: .translation, directoryURL: directory)
        try firstExecutionStore.save(executionKey)
        try firstTranslationStore.save(translationKey)
        let executionBytes = try Data(contentsOf: firstExecutionStore.fileURL)
        let translationBytes = try Data(contentsOf: firstTranslationStore.fileURL)
        let reopenedExecution = ExecutionViewModel(store: executionStore, credentials: FileCredentialStore(scope: .execution, directoryURL: directory))
        let reopenedTranslation = TranslationViewModel(provider: UnavailableTranslationProvider(), configurationStore: translationStore,
                                                        credentials: FileCredentialStore(scope: .translation, directoryURL: directory))
        reopenedExecution.restoreSavedKeyForSettings()
        reopenedTranslation.restoreSavedKeyForSettings()
        check("fresh_file_instances_restore_both_saved_scopes", reopenedExecution.apiKey == executionKey && reopenedTranslation.apiKey == translationKey)
        check("file_restore_preserves_saved_bytes", try Data(contentsOf: firstExecutionStore.fileURL) == executionBytes &&
              Data(contentsOf: firstTranslationStore.fileURL) == translationBytes)
    } catch { check("temporary_file_reopen_fixture", false) }
    do {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        check("temporary_files_are_removed", !FileManager.default.fileExists(atPath: root.path))
    } catch { check("temporary_files_are_removed", false) }
    return results
}
