import Darwin
import Foundation

/// Synthetic account credentials and isolated temporary files only.
func subscriptionAccountStoreChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("subscription_accounts_store_" + name, passed)) }
    func expectFailure(_ name: String, _ expected: SubscriptionAccountStoreFailure, operation: () throws -> Void) {
        do { try operation(); check(name, false) }
        catch let failure as SubscriptionAccountStoreFailure { check(name, failure == expected && !failure.message.isEmpty) }
        catch { check(name, false) }
    }
    func expectInvalidToken(_ name: String, operation: () throws -> Void) {
        do { try operation(); check(name, false) }
        catch let failure as LocalCredentialFailure { check(name, failure == .invalidSubscriptionToken) }
        catch { check(name, false) }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("subscription-account-checks-\(UUID().uuidString)", isDirectory: true)
    let directory = root.appendingPathComponent("Credentials", isDirectory: true)
    let tokenA = "sk-ant-oat01-fake-subscription-account-alpha"
    let tokenB = "sk-ant-oat01-fake-subscription-account-beta"
    let tokenBUpdated = "sk-ant-oat01-fake-subscription-account-beta-updated"
    do {
        let legacy = FileCredentialStore(scope: .subscription, directoryURL: directory)
        try legacy.save(tokenA)
        let legacyBytes = try Data(contentsOf: legacy.fileURL)
        let store = FileSubscriptionAccountStore(directoryURL: directory)
        let migrated = try store.load()
        check("legacy_migrates_one_account", migrated.accounts.count == 1 && migrated.accounts.first?.token == tokenA)
        check("legacy_migration_selects_account", migrated.currentAccountID != nil && migrated.currentAccountID == migrated.accounts.first?.id)
        check("legacy_migration_labels_default_account", migrated.accounts.first?.label == "默认账号")
        check("legacy_file_kept_byte_identical", try Data(contentsOf: legacy.fileURL) == legacyBytes)
        check("legacy_migration_survives_restart", try FileSubscriptionAccountStore(directoryURL: directory).load() == migrated)
        check("vault_filename_is_stable", store.fileURL.lastPathComponent == "subscription-accounts.json")
        check("directory_is_owner_only", (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        check("vault_is_owner_only", (try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        guard let accountA = migrated.accounts.first else { throw SubscriptionAccountStoreFailure.invalidFormat }
        var accountB = SubscriptionAccount(label: "工作账号 B", token: tokenB)
        var catalog = SubscriptionAccountCatalog(currentAccountID: accountB.id, accounts: [accountA, accountB])
        try store.save(catalog)
        check("two_accounts_survive_restart", try FileSubscriptionAccountStore(directoryURL: directory).load() == catalog)
        check("selected_account_is_saved", try store.load().currentAccountID == accountB.id)
        let originalVersion = accountB.credentialVersion
        accountB.token = tokenBUpdated
        accountB.credentialVersion = UUID()
        catalog.accounts[1] = accountB
        try store.save(catalog)
        let updated = try store.load()
        check("credential_update_keeps_other_account_exact", updated.accounts[0] == accountA)
        check("credential_update_is_independent", updated.accounts[1].token == tokenBUpdated && updated.accounts[1].credentialVersion != originalVersion)
        check("updates_do_not_copy_into_legacy_slot", try Data(contentsOf: legacy.fileURL) == legacyBytes)
        catalog.currentAccountID = accountA.id
        try store.save(catalog)
        check("selection_changes_no_credentials", try store.load().accounts == updated.accounts)
        catalog.accounts[1].token = nil
        catalog.accounts[1].credentialVersion = UUID()
        try store.save(catalog)
        let withoutAuthorization = try store.load()
        check("cleared_authorization_keeps_account_record", withoutAuthorization.accounts[1].id == accountB.id && withoutAuthorization.accounts[1].token == nil)
        check("cleared_authorization_keeps_other_account", withoutAuthorization.accounts[0] == accountA)
        let encoded = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [String: Any]
        check("vault_has_only_version_selection_accounts", Set(encoded.keys) == ["schemaVersion", "currentAccountID", "accounts"])
        let encodedAccounts = encoded["accounts"] as! [[String: Any]]
        check("account_has_only_identity_label_token_version", Set(encodedAccounts[1].keys) == ["id", "label", "token", "credentialVersion"])
        check("cleared_token_is_explicit_null", encodedAccounts[1]["token"] is NSNull)

        let savedBytes = try Data(contentsOf: store.fileURL)
        let failing = FileSubscriptionAccountStore(directoryURL: directory, atomicReplace: { _, _ in throw SubscriptionAccountStoreFailure.saveFailed })
        var changed = catalog
        changed.accounts[0].label = "修改后"
        expectFailure("atomic_replace_failure_reported", .saveFailed) { try failing.save(changed) }
        check("atomic_failure_preserves_vault_bytes", try Data(contentsOf: store.fileURL) == savedBytes)
        check("atomic_failure_preserves_reloaded_catalog", try failing.load() == catalog)
        check("atomic_failure_removes_temporary_file", try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["subscription-token.json", "subscription-accounts.json"])
        let noReplacement = FileSubscriptionAccountStore(directoryURL: directory, atomicReplace: { _, _ in })
        expectFailure("no_op_replace_is_readback_failure", .readbackFailed) { try noReplacement.save(changed) }
        check("no_op_replace_preserves_original_bytes", try Data(contentsOf: store.fileURL) == savedBytes)
        check("no_op_replace_cleans_temporary_file", try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["subscription-token.json", "subscription-accounts.json"])
        let invalidReadbackBytes = Data("corrupted-after-atomic-replacement".utf8)
        let corruptAfterReplacement = FileSubscriptionAccountStore(directoryURL: directory, atomicReplace: { temporary, destination in
            guard Darwin.rename(temporary.path, destination.path) == 0 else { throw SubscriptionAccountStoreFailure.saveFailed }
            try invalidReadbackBytes.write(to: destination)
        })
        expectFailure("committed_invalid_json_is_readback_failure", .readbackFailed) { try corruptAfterReplacement.save(changed) }
        check("readback_failure_does_not_claim_old_bytes_preserved", try Data(contentsOf: store.fileURL) == invalidReadbackBytes)
        check("readback_failure_cleans_temporary_file", try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["subscription-token.json", "subscription-accounts.json"])
        try savedBytes.write(to: store.fileURL)

        func malformed(_ name: String, bytes: Data, expected: SubscriptionAccountStoreFailure) throws {
            try bytes.write(to: store.fileURL)
            let fresh = FileSubscriptionAccountStore(directoryURL: directory)
            expectFailure(name + "_load_rejected", expected) { _ = try fresh.load() }
            expectFailure(name + "_save_rejected", expected) { try fresh.save(catalog) }
            check(name + "_bytes_preserved", try Data(contentsOf: store.fileURL) == bytes)
            try savedBytes.write(to: store.fileURL)
            check(name + "_recovery_uses_persisted_catalog", try fresh.load() == catalog)
        }
        func malformedObject(_ name: String, _ object: Any, _ expected: SubscriptionAccountStoreFailure = .invalidFormat) throws {
            try malformed(name, bytes: JSONSerialization.data(withJSONObject: object), expected: expected)
        }
        try malformed("invalid_json", bytes: Data("not-account-json".utf8), expected: .invalidFormat)
        try malformed("invalid_utf8", bytes: Data([0xFF, 0xFE]), expected: .invalidFormat)
        var malformedCatalog = encoded
        malformedCatalog["schemaVersion"] = 2
        try malformedObject("future_version", malformedCatalog, .unsupportedVersion)
        malformedCatalog = encoded; malformedCatalog["schemaVersion"] = true
        try malformedObject("boolean_version", malformedCatalog)
        malformedCatalog = encoded; malformedCatalog["unexpected"] = "ignored"
        try malformedObject("unknown_catalog_field", malformedCatalog)
        malformedCatalog = encoded; malformedCatalog.removeValue(forKey: "currentAccountID")
        try malformedObject("missing_selection_field", malformedCatalog)
        malformedCatalog = encoded; malformedCatalog["currentAccountID"] = UUID().uuidString
        try malformedObject("dangling_selection", malformedCatalog)
        malformedCatalog = encoded; malformedCatalog["accounts"] = []
        try malformedObject("selection_with_empty_accounts", malformedCatalog)
        malformedCatalog = encoded; malformedCatalog["accounts"] = [encodedAccounts[0], encodedAccounts[0]]
        try malformedObject("duplicate_account_id", malformedCatalog)
        var malformedAccount = encodedAccounts[0]
        malformedAccount["unexpected"] = "ignored"
        malformedCatalog = encoded; malformedCatalog["accounts"] = [malformedAccount, encodedAccounts[1]]
        try malformedObject("unknown_account_field", malformedCatalog)
        malformedAccount = encodedAccounts[0]; malformedAccount["id"] = "not-a-uuid"
        malformedCatalog = encoded; malformedCatalog["accounts"] = [malformedAccount, encodedAccounts[1]]
        try malformedObject("invalid_account_id", malformedCatalog)
        malformedAccount = encodedAccounts[0]; malformedAccount["credentialVersion"] = "not-a-uuid"
        malformedCatalog = encoded; malformedCatalog["accounts"] = [malformedAccount, encodedAccounts[1]]
        try malformedObject("invalid_credential_version", malformedCatalog)
        malformedAccount = encodedAccounts[0]; malformedAccount.removeValue(forKey: "token")
        malformedCatalog = encoded; malformedCatalog["accounts"] = [malformedAccount, encodedAccounts[1]]
        try malformedObject("missing_token_field", malformedCatalog)
        try malformed("oversized_vault", bytes: Data(repeating: 32, count: FileSubscriptionAccountStore.maximumBytes + 1), expected: .fileTooLarge)

        for (name, label) in [("empty", ""), ("leading_space", " 账号"), ("trailing_space", "账号 "), ("newline", "账号\nB"), ("control", "账号\u{7F}"), ("too_many_characters", String(repeating: "账", count: 81))] {
            var invalid = catalog
            invalid.accounts[0].label = label
            expectFailure("invalid_label_" + name, .invalidLabel) { try store.save(invalid) }
            check("invalid_label_" + name + "_preserves_bytes", try Data(contentsOf: store.fileURL) == savedBytes)
        }
        var invalidTokenCatalog = catalog
        invalidTokenCatalog.accounts[0].token = "not-a-subscription-token"
        expectInvalidToken("invalid_token_on_save_rejected") { try store.save(invalidTokenCatalog) }
        check("invalid_token_save_preserves_vault", try Data(contentsOf: store.fileURL) == savedBytes)
        malformedAccount = encodedAccounts[0]; malformedAccount["token"] = "not-a-subscription-token"
        malformedCatalog = encoded; malformedCatalog["accounts"] = [malformedAccount, encodedAccounts[1]]
        let invalidTokenBytes = try JSONSerialization.data(withJSONObject: malformedCatalog)
        try invalidTokenBytes.write(to: store.fileURL)
        expectInvalidToken("invalid_persisted_token_rejected") { _ = try store.load() }
        expectInvalidToken("invalid_persisted_token_blocks_save") { try store.save(catalog) }
        check("invalid_persisted_token_bytes_preserved", try Data(contentsOf: store.fileURL) == invalidTokenBytes)
        try savedBytes.write(to: store.fileURL)
        let tooMany = SubscriptionAccountCatalog(accounts: (0...SubscriptionAccountCatalog.maximumAccounts).map { SubscriptionAccount(label: "账号 \($0)", token: nil) })
        expectFailure("account_count_bound_enforced", .tooManyAccounts) { try store.save(tooMany) }
        check("account_count_failure_preserves_vault", try Data(contentsOf: store.fileURL) == savedBytes)

        let unrelated = root.appendingPathComponent("unrelated-vault.json")
        try savedBytes.write(to: unrelated)
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: unrelated)
        expectFailure("symlink_file_load_rejected", .readFailed) { _ = try store.load() }
        expectFailure("symlink_file_save_rejected", .readFailed) { try store.save(catalog) }
        check("symlink_target_untouched", try Data(contentsOf: unrelated) == savedBytes)
        try FileManager.default.removeItem(at: store.fileURL)
        try savedBytes.write(to: store.fileURL)
        let linkedDirectory = root.appendingPathComponent("linked-credentials")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: directory)
        let linked = FileSubscriptionAccountStore(directoryURL: linkedDirectory)
        expectFailure("symlink_directory_load_rejected", .readFailed) { _ = try linked.load() }
        expectFailure("symlink_directory_save_rejected", .readFailed) { try linked.save(catalog) }
        check("symlink_directory_target_untouched", try Data(contentsOf: store.fileURL) == savedBytes)

        let emptyDirectory = root.appendingPathComponent("EmptyCredentials")
        let empty = FileSubscriptionAccountStore(directoryURL: emptyDirectory)
        check("missing_credentials_create_empty_vault", try empty.load() == SubscriptionAccountCatalog())
        let emptyBytes = try Data(contentsOf: empty.fileURL)
        let emptyObject = try JSONSerialization.jsonObject(with: emptyBytes) as! [String: Any]
        check("empty_vault_has_explicit_null_selection", emptyObject["currentAccountID"] is NSNull)
        try FileCredentialStore(scope: .subscription, directoryURL: emptyDirectory).save(tokenB)
        check("empty_vault_never_falls_back_to_later_legacy_token", try FileSubscriptionAccountStore(directoryURL: emptyDirectory).load() == SubscriptionAccountCatalog())
        check("empty_vault_stays_byte_identical", try Data(contentsOf: empty.fileURL) == emptyBytes)
        try store.save(SubscriptionAccountCatalog())
        check("deleting_all_accounts_does_not_restore_legacy", try FileSubscriptionAccountStore(directoryURL: directory).load() == SubscriptionAccountCatalog())
        check("delete_all_preserves_legacy_rollback_bytes", try Data(contentsOf: legacy.fileURL) == legacyBytes)

        let migrationDirectory = root.appendingPathComponent("FailedMigration")
        let migrationLegacy = FileCredentialStore(scope: .subscription, directoryURL: migrationDirectory)
        try migrationLegacy.save(tokenA)
        let migrationLegacyBytes = try Data(contentsOf: migrationLegacy.fileURL)
        let failingMigration = FileSubscriptionAccountStore(directoryURL: migrationDirectory, atomicReplace: { _, _ in throw SubscriptionAccountStoreFailure.saveFailed })
        do { _ = try failingMigration.load(); check("migration_failure_reported", false) }
        catch let failure as SubscriptionAccountStoreFailure { check("migration_failure_reported", failure == .saveFailed || failure == .migrationFailed) }
        catch { check("migration_failure_reported", false) }
        check("migration_failure_keeps_legacy_bytes", try Data(contentsOf: migrationLegacy.fileURL) == migrationLegacyBytes)
        check("migration_failure_does_not_leave_vault", !FileManager.default.fileExists(atPath: failingMigration.fileURL.path))
        check("migration_can_retry", try FileSubscriptionAccountStore(directoryURL: migrationDirectory).load().accounts.first?.token == tokenA)
        let unreadableLegacy = MemoryAppCredentialStore(tokenA, scope: .subscription)
        unreadableLegacy.loadFailure = .readFailed
        let unreadableMigration = FileSubscriptionAccountStore(directoryURL: root.appendingPathComponent("UnreadableMigration"), legacyCredentials: unreadableLegacy)
        expectFailure("legacy_load_failure_is_migration_failure", .migrationFailed) { _ = try unreadableMigration.load() }
        check("legacy_load_failure_creates_no_vault", !FileManager.default.fileExists(atPath: unreadableMigration.fileURL.path))
        var unselected = catalog
        unselected.currentAccountID = nil
        try store.save(unselected)
        let unselectedReloaded = try FileSubscriptionAccountStore(directoryURL: directory).load()
        check("accounts_can_remain_unselected", unselectedReloaded.currentAccountID == nil && unselectedReloaded.accounts == catalog.accounts)

        let memory = MemorySubscriptionAccountStore(catalog: catalog)
        check("memory_load_matches_fixture", try memory.load() == catalog)
        memory.saveFailure = .saveFailed
        expectFailure("memory_save_failure_reported", .saveFailed) { try memory.save(changed) }
        check("memory_failed_save_preserves_catalog", try memory.load() == catalog && memory.saveCount == 0)
        memory.saveFailure = nil
        try memory.save(changed)
        check("memory_save_commits_catalog", try memory.load() == changed && memory.saveCount == 1)
        memory.loadFailure = .readFailed
        expectFailure("memory_load_failure_reported", .readFailed) { _ = try memory.load() }

        try FileManager.default.removeItem(at: root)
        check("temporary_directory_removed", !FileManager.default.fileExists(atPath: root.path))
    } catch {
        check("setup_or_operation_failed", false)
        if FileManager.default.fileExists(atPath: root.path) {
            do { try FileManager.default.removeItem(at: root) }
            catch { check("temporary_cleanup_failed", false) }
        }
    }
    return results
}
