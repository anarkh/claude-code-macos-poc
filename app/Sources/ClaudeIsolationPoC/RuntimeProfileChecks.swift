import Foundation

@MainActor
func runtimeProfileChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("runtime_profile_" + name, passed)) }
    func rejected(_ action: () throws -> Void) -> Bool {
        do { try action(); return false }
        catch let failure as RuntimeProfileFailure { return failure == .invalid }
        catch { return false }
    }
    let suiteName = "com.claude-isolation-poc.runtime-profile-tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        return [("runtime_profile_test_suite_available", false)]
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = RuntimeProfileStore(defaults: defaults)
    let english = AppRuntimeProfile(timeZone: "America/New_York", language: "en")
    let fields: [String: Any] = ["schema": english.schema, "timeZone": english.timeZone, "language": english.language]
    do {
        check("missing_uses_japan_preset", try store.load() == .japan)
        let data = try JSONEncoder().encode(english)
        check("codable_roundtrip", try JSONDecoder().decode(AppRuntimeProfile.self, from: data) == english)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        check("only_three_public_fields", object.map { Set($0.keys) == Set(["schema", "timeZone", "language"]) } ?? false)
        let unrelated: [(String, Data)] = [
            (NetworkConfigurationStore.storageKey, Data("network-public-fixture".utf8)),
            (ExecutionConfigurationStore.storageKey, Data("execution-public-fixture".utf8)),
            (TranslationConfigurationStore.storageKey, Data("translation-public-fixture".utf8))
        ]
        for (key, value) in unrelated { defaults.set(value, forKey: key) }
        try store.save(english)
        check("persist_readback", try store.load() == english)
        if let reopened = UserDefaults(suiteName: suiteName) {
            check("reopened_store_reads_saved_profile", try RuntimeProfileStore(defaults: reopened).load() == english)
        } else { check("reopened_store_reads_saved_profile", false) }
        check("save_preserves_other_settings", unrelated.allSatisfy { defaults.data(forKey: $0.0) == $0.1 })
        let priorData = defaults.data(forKey: RuntimeProfileStore.storageKey)
        check("invalid_save_rejected", rejected { try store.save(.init(timeZone: "GMT+09:00", language: "ja")) })
        check("invalid_save_preserves_previous_profile", try store.load() == english && defaults.data(forKey: RuntimeProfileStore.storageKey) == priorData)
        check("fixed_provider_validates_snapshot", try FixedRuntimeProfileProvider(profile: english).snapshot() == english)
        check("fixed_default_is_japan", try FixedRuntimeProfileProvider().snapshot() == .japan)
        check("fixed_provider_rejects_invalid_profile", rejected { _ = try FixedRuntimeProfileProvider(profile: .init(timeZone: "Asia/Tokyo", language: "fr")).snapshot() })
    } catch { check("persistence_roundtrip_setup", false) }

    for (zone, language) in [("Asia/Tokyo", "ja"), ("UTC", "en"), ("Asia/Shanghai", "zh"), ("America/New_York", "en")] {
        do {
            try AppRuntimeProfile(timeZone: zone, language: language).validate()
            check("valid_" + zone.replacingOccurrences(of: "/", with: "_") + "_" + language, true)
        } catch { check("valid_" + zone.replacingOccurrences(of: "/", with: "_") + "_" + language, false) }
    }
    for (name, zone) in [
        ("empty", ""), ("unknown", "Mars/Olympus"), ("posix", "JST-9"),
        ("gmt", "GMT"), ("gmt_offset", "GMT+09:00"), ("lowercase", "asia/tokyo"), ("leading_space", " Asia/Tokyo"),
        ("trailing_space", "Asia/Tokyo "), ("newline", "Asia/Tokyo\n"),
        ("unicode", "アジア/東京"), ("nul", "Asia/Tokyo\0"), ("oversized", String(repeating: "A", count: 129))
    ] { check("invalid_time_zone_" + name, rejected { try AppRuntimeProfile(timeZone: zone, language: "ja").validate() }) }
    for (name, language) in [
        ("empty", ""), ("unsupported", "fr"), ("locale", "ja_JP.UTF-8"), ("uppercase", "JA"),
        ("leading_space", " ja"), ("trailing_space", "ja "), ("newline", "ja\n"), ("bcp47", "ja-JP")
    ] { check("invalid_language_" + name, rejected { try AppRuntimeProfile(timeZone: "Asia/Tokyo", language: language).validate() }) }
    check("unknown_schema_validation_rejected", rejected { try AppRuntimeProfile(schema: "app-runtime-profile/v2", timeZone: "Asia/Tokyo", language: "ja").validate() })
    for (language, locale) in [("ja", "ja_JP.UTF-8"), ("en", "en_US.UTF-8"), ("zh", "zh_CN.UTF-8")] {
        let profile = AppRuntimeProfile(timeZone: "UTC", language: language)
        check("process_environment_" + language, profile.processEnvironment == [
            "PATH": "/usr/bin:/bin", "TZ": "UTC", "LANG": locale, "LC_ALL": locale, "LC_MESSAGES": locale
        ])
    }
    check("japan_environment_uses_tokyo", AppRuntimeProfile.japan.processEnvironment["TZ"] == "Asia/Tokyo")
    check("environment_does_not_inherit_host_values", AppRuntimeProfile.japan.processEnvironment.keys.sorted() == ["LANG", "LC_ALL", "LC_MESSAGES", "PATH", "TZ"])

    func invalidPayload(_ name: String, _ payload: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            defaults.set(data, forKey: RuntimeProfileStore.storageKey)
            check(name, rejected { _ = try store.load() })
            check(name + "_decode", rejected { _ = try JSONDecoder().decode(AppRuntimeProfile.self, from: data) })
        } catch { check(name + "_setup", false) }
    }
    var unknownSchema = fields; unknownSchema["schema"] = "app-runtime-profile/v2"
    invalidPayload("unknown_schema_rejected_without_default", unknownSchema)
    var missing = fields; missing.removeValue(forKey: "timeZone")
    invalidPayload("missing_time_zone_rejected", missing)
    var unknownField = fields; unknownField["inheritHostEnvironment"] = true
    invalidPayload("unknown_field_rejected", unknownField)
    var wrongType = fields; wrongType["language"] = 1
    invalidPayload("wrong_type_rejected", wrongType)
    var invalidZone = fields; invalidZone["timeZone"] = "JST-9"
    invalidPayload("invalid_saved_time_zone_rejected", invalidZone)
    var invalidLanguage = fields; invalidLanguage["language"] = "fr"
    invalidPayload("invalid_saved_language_rejected", invalidLanguage)
    defaults.set("not-runtime-profile-data", forKey: RuntimeProfileStore.storageKey)
    check("wrong_storage_type_rejected", rejected { _ = try store.load() })
    defaults.set(Data("not-json".utf8), forKey: RuntimeProfileStore.storageKey)
    check("malformed_json_rejected", rejected { _ = try store.load() })
    defaults.set(Data("[]".utf8), forKey: RuntimeProfileStore.storageKey)
    check("array_json_rejected", rejected { _ = try store.load() })
    defaults.set(Data(repeating: 32, count: RuntimeProfileStore.maximumBytes + 1), forKey: RuntimeProfileStore.storageKey)
    check("oversized_saved_profile_rejected", rejected { _ = try store.load() })

    do {
        try store.save(english)
        let model = RuntimeSettingsViewModel(store: store)
        check("view_model_loads_saved_profile", model.timeZone == english.timeZone && model.language == english.language && model.error == nil)
        model.timeZone = "JST-9"; model.save()
        check("invalid_save_keeps_draft_and_shows_unsaved_status", model.timeZone == "JST-9" && model.language == "en" && model.status.contains("保存未完成") && model.error == RuntimeProfileFailure.invalid.message)
        check("invalid_view_model_save_keeps_saved_profile", try store.load() == english)
        model.timeZone = "UTC"; model.save()
        check("time_zone_can_change_independently", try store.load() == .init(timeZone: "UTC", language: "en") && model.error == nil)
        model.language = "zh"; model.save()
        check("language_can_change_independently", try store.load() == .init(timeZone: "UTC", language: "zh") && model.error == nil)
        model.useJapanPreset()
        check("japan_button_saves_and_updates_form", try store.load() == .japan && model.timeZone == "Asia/Tokyo" && model.language == "ja" && model.error == nil)
        check("saved_status_mentions_next_request", model.status.contains("下一次请求"))
        model.chooseTimeZone("UTC")
        check("single_choice_marks_pending_and_preserves_language", model.timeZone == "UTC" && model.language == "ja" && model.error == nil && model.status.contains("点击保存"))
        check("single_choice_does_not_save_implicitly", try store.load() == .japan)
        model.chooseTimeZone("Mars/Olympus")
        check("invalid_choice_keeps_selection_and_shows_error", model.timeZone == "UTC" && model.error == RuntimeProfileFailure.invalid.message && model.status.contains("选择未完成"))
        check("invalid_choice_keeps_saved_profile", try store.load() == .japan)
        model.chooseTimeZone("America/New_York")
        check("legal_choice_recovers_from_error", model.timeZone == "America/New_York" && model.error == nil && model.status.contains("点击保存"))
        model.save()
        check("single_choice_saves_selected_identifier", try store.load() == .init(timeZone: "America/New_York", language: "ja") && model.status.contains("已保存"))
        let beforeFixture = defaults.data(forKey: RuntimeProfileStore.storageKey)
        let memoryStore = MemoryRuntimeProfileStore()
        let fixtureModel = RuntimeSettingsViewModel(store: memoryStore)
        fixtureModel.timeZone = english.timeZone; fixtureModel.language = english.language; fixtureModel.save()
        check("fixture_memory_profile_saved", try memoryStore.load() == english)
        check("fixture_store_independent_of_saved_defaults", defaults.data(forKey: RuntimeProfileStore.storageKey) == beforeFixture)
    } catch { check("view_model_persistence_setup", false) }

    let faultStore = RuntimeCheckStore(profile: english)
    let failingModel = RuntimeSettingsViewModel(store: faultStore)
    faultStore.failSave = true
    failingModel.timeZone = "UTC"; failingModel.language = "zh"; failingModel.save()
    check("persistence_failure_is_actionable", failingModel.error == RuntimeProfileFailure.persistenceFailed.message)
    check("persistence_failure_keeps_old_profile_and_draft", faultStore.profile == english && failingModel.timeZone == "UTC" && failingModel.language == "zh" && failingModel.status.contains("保存未完成"))
    failingModel.useJapanPreset()
    check("preset_failure_keeps_saved_profile_and_draft", faultStore.profile == english && failingModel.timeZone == "UTC" && failingModel.language == "zh")
    faultStore.failSave = false; faultStore.mismatchReadback = true
    failingModel.save()
    check("save_readback_mismatch_is_explicit", failingModel.error == RuntimeProfileFailure.persistenceFailed.message)
    faultStore.failLoad = true
    let invalidModel = RuntimeSettingsViewModel(store: faultStore)
    check("load_failure_does_not_show_preset_as_saved", invalidModel.timeZone.isEmpty && invalidModel.language.isEmpty && invalidModel.error == RuntimeProfileFailure.invalid.message)
    check("required_failure_guides_settings", RuntimeProfileFailure.required.code == "RUNTIME_PROFILE_REQUIRED" && RuntimeProfileFailure.required.message.contains("运行环境"))
    return results
}

private final class RuntimeCheckStore: RuntimeProfilePersisting {
    var profile: AppRuntimeProfile
    var failSave = false
    var failLoad = false
    var mismatchReadback = false
    init(profile: AppRuntimeProfile) { self.profile = profile }
    func load() throws -> AppRuntimeProfile {
        if failLoad { throw RuntimeProfileFailure.invalid }
        return mismatchReadback ? .japan : profile
    }
    func save(_ profile: AppRuntimeProfile) throws {
        if failSave { throw RuntimeProfileFailure.persistenceFailed }
        self.profile = profile
    }
}
