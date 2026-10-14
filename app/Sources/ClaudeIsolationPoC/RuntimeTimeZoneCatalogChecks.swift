import Foundation

func runtimeTimeZoneCatalogChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ passed: Bool) { results.append(("runtime_time_zone_catalog_" + name, passed)) }
    let options = RuntimeTimeZoneCatalog.options
    let identifiers = options.map(\.id)
    let available = AppRuntimeProfile.availableTimeZones
    let identifierSet = Set(identifiers)
    func search(_ query: String) -> [String] { RuntimeTimeZoneCatalog.filtered(query: query).map(\.id) }

    check("catalog_matches_validation_list", identifiers == available)
    check("identifiers_are_unique", identifierSet.count == identifiers.count)
    check("utc_is_first", identifiers.first == "UTC")
    check("remaining_ids_are_sorted", Array(identifiers.dropFirst()) == identifiers.dropFirst().sorted())
    check("japan_preset_is_selectable", identifierSet.contains(AppRuntimeProfile.japan.timeZone))
    check("labels_are_nonempty", options.allSatisfy { !$0.label.isEmpty })
    check("all_options_pass_runtime_validation", options.allSatisfy { option in
        do { try AppRuntimeProfile(timeZone: option.id, language: "ja").validate(); return true }
        catch { return false }
    })
    check("empty_query_returns_all_options", RuntimeTimeZoneCatalog.filtered(query: "") == options)
    check("whitespace_query_returns_all_options", RuntimeTimeZoneCatalog.filtered(query: " \n\t ") == options)
    check("id_search_is_case_insensitive_and_trimmed", search(" \tASIA/tOkYo \n") == ["Asia/Tokyo"])
    check("japan_chinese_alias", search("日本") == ["Asia/Tokyo"])
    check("tokyo_chinese_alias", search("东京") == ["Asia/Tokyo"])
    check("tokyo_traditional_alias", search("東京") == ["Asia/Tokyo"])
    check("shanghai_chinese_alias", search("上海").contains("Asia/Shanghai"))
    check("china_traditional_alias", search("中國") == ["Asia/Shanghai"])
    check("utc_chinese_alias", search("世界标准时间") == ["UTC"])
    check("query_tokens_use_and_matching", search("tokyo 日本") == ["Asia/Tokyo"] && search("tokyo 上海").isEmpty)
    check("city_words_can_be_searched", search("new york").contains("America/New_York"))
    check("unknown_query_returns_empty", RuntimeTimeZoneCatalog.filtered(query: "Mars/Olympus").isEmpty)
    check("search_returns_only_legal_unique_options", ["ASIA", "日本", "标准", "UTC", "new york"].allSatisfy { query in
        let filtered = RuntimeTimeZoneCatalog.filtered(query: query)
        return Set(filtered.map(\.id)).count == filtered.count && filtered.allSatisfy { identifierSet.contains($0.id) }
    })
    return results
}
