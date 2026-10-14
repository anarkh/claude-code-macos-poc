import Foundation

enum RuntimeProfileFailure: Error, Equatable, Sendable {
    case required
    case invalid
    case persistenceFailed

    var code: String {
        switch self {
        case .required: "RUNTIME_PROFILE_REQUIRED"
        case .invalid: "RUNTIME_PROFILE_INVALID"
        case .persistenceFailed: "RUNTIME_PROFILE_SAVE_FAILED"
        }
    }

    var message: String {
        switch self {
        case .required: "缺少运行环境配置，请在设置的运行环境页面保存时区和语言。"
        case .invalid: "运行环境配置无效。请选择日语、英语或中文，并填写合法 IANA 时区，例如 Asia/Tokyo 或 UTC；请重新保存。"
        case .persistenceFailed: "运行环境配置未能确认保存，请重新保存后再试。"
        }
    }
}

struct AppRuntimeProfile: Codable, Equatable, Sendable {
    let schema: String
    let timeZone: String
    let language: String

    static let japan = AppRuntimeProfile(timeZone: "Asia/Tokyo", language: "ja")
    static let availableTimeZones = ["UTC"] + Set(TimeZone.knownTimeZoneIdentifiers.filter {
        $0.contains("/") && !$0.isEmpty && $0.utf8.count <= 128 && $0.utf8.allSatisfy { $0 < 128 }
    }).sorted()
    private static let allowedTimeZones = Set(availableTimeZones)
    private static let locales = ["ja": "ja_JP.UTF-8", "en": "en_US.UTF-8", "zh": "zh_CN.UTF-8"]

    init(schema: String = "app-runtime-profile/v1", timeZone: String, language: String) {
        self.schema = schema
        self.timeZone = timeZone
        self.language = language
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case schema, timeZone, language }

    init(from decoder: any Decoder) throws {
        do {
            let fields = try decoder.container(keyedBy: RuntimeProfileCodingKey.self)
            let allowed = Set(CodingKeys.allCases.map(\.rawValue))
            guard fields.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
                throw RuntimeProfileFailure.invalid
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schema = try values.decode(String.self, forKey: .schema)
            timeZone = try values.decode(String.self, forKey: .timeZone)
            language = try values.decode(String.self, forKey: .language)
            try validate()
        } catch { throw RuntimeProfileFailure.invalid }
    }

    func validate() throws {
        guard schema == "app-runtime-profile/v1",
              !timeZone.isEmpty, timeZone.utf8.count <= 128,
              timeZone.utf8.allSatisfy({ $0 < 128 }),
              Self.allowedTimeZones.contains(timeZone),
              Self.locales[language] != nil else {
            throw RuntimeProfileFailure.invalid
        }
    }

    // Process launchers obtain a validated snapshot before reading this environment.
    var processEnvironment: [String: String] {
        guard let locale = Self.locales[language] else {
            preconditionFailure("A validated runtime profile is required for process launch.")
        }
        return ["PATH": "/usr/bin:/bin", "TZ": timeZone, "LANG": locale,
                "LC_ALL": locale, "LC_MESSAGES": locale]
    }
}

private struct RuntimeProfileCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

protocol RuntimeProfileProviding: Sendable {
    func snapshot() throws -> AppRuntimeProfile
}

struct SavedRuntimeProfileProvider: RuntimeProfileProviding {
    func snapshot() throws -> AppRuntimeProfile { try RuntimeProfileStore().load() }
}

struct FixedRuntimeProfileProvider: RuntimeProfileProviding {
    let profile: AppRuntimeProfile
    init(profile: AppRuntimeProfile = .japan) { self.profile = profile }
    func snapshot() throws -> AppRuntimeProfile {
        try profile.validate()
        return profile
    }
}

protocol RuntimeProfilePersisting {
    func load() throws -> AppRuntimeProfile
    func save(_ profile: AppRuntimeProfile) throws
}

struct RuntimeProfileStore: RuntimeProfilePersisting {
    static let storageKey = "claude-code.runtime-profile.v1"
    static let maximumBytes = 1_024
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() throws -> AppRuntimeProfile {
        guard let stored = defaults.object(forKey: Self.storageKey) else { return .japan }
        guard let data = stored as? Data, data.count <= Self.maximumBytes else {
            throw RuntimeProfileFailure.invalid
        }
        do { return try JSONDecoder().decode(AppRuntimeProfile.self, from: data) }
        catch { throw RuntimeProfileFailure.invalid }
    }

    func save(_ profile: AppRuntimeProfile) throws {
        try profile.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(profile) }
        catch { throw RuntimeProfileFailure.invalid }
        guard data.count <= Self.maximumBytes else { throw RuntimeProfileFailure.invalid }
        defaults.set(data, forKey: Self.storageKey)
        guard defaults.data(forKey: Self.storageKey) == data else { throw RuntimeProfileFailure.persistenceFailed }
        do {
            guard try load() == profile else { throw RuntimeProfileFailure.persistenceFailed }
        } catch { throw RuntimeProfileFailure.persistenceFailed }
    }
}

final class MemoryRuntimeProfileStore: RuntimeProfilePersisting {
    private var profile: AppRuntimeProfile
    init(profile: AppRuntimeProfile = .japan) { self.profile = profile }
    func load() throws -> AppRuntimeProfile {
        try profile.validate()
        return profile
    }
    func save(_ profile: AppRuntimeProfile) throws {
        try profile.validate()
        self.profile = profile
    }
}
