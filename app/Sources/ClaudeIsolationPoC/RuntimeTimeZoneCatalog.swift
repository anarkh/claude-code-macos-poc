import Foundation

struct RuntimeTimeZoneOption: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
}

enum RuntimeTimeZoneCatalog {
    static let options: [RuntimeTimeZoneOption] = AppRuntimeProfile.availableTimeZones.map { identifier in
        if identifier == "UTC" {
            return RuntimeTimeZoneOption(id: identifier, label: "协调世界时")
        }
        let city = identifier.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? identifier
        let name = TimeZone(identifier: identifier)?.localizedName(for: .standard, locale: Locale(identifier: "zh_CN"))
        let label = name.map { $0 + " · " + city } ?? city
        return RuntimeTimeZoneOption(id: identifier, label: label)
    }

    private static let aliases: [String: String] = [
        "Asia/Tokyo": "东京 東京 日本",
        "Asia/Shanghai": "上海 中国 中國",
        "UTC": "协调世界时 世界标准时间"
    ]

    static func filtered(query: String) -> [RuntimeTimeZoneOption] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return options }
        return options.filter { option in
            let text = option.id + " " + option.label + " " + (aliases[option.id] ?? "")
            return tokens.allSatisfy {
                text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
            }
        }
    }
}
