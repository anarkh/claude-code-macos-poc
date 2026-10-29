import CoreFoundation
import Foundation
import SwiftUI

@MainActor
final class DiagnosticsSettingsModel: ObservableObject {
    static let storageKey = "diagnostics.capture-request-bodies.v1"
    @Published private(set) var captureBodies = false
    @Published private(set) var error: String?
    private let defaults: UserDefaults?

    /// A nil store is deliberately memory-only for fixtures and checks.
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        guard let value = defaults?.object(forKey: Self.storageKey) else { return }
        guard let enabled = Self.boolean(value) else {
            error = "诊断设置格式无效，当前仅保存摘要；请重新选择正文采集设置。"
            return
        }
        captureBodies = enabled
    }

    func setCaptureBodies(_ value: Bool) {
        if let defaults {
            defaults.set(value, forKey: Self.storageKey)
            guard let stored = defaults.object(forKey: Self.storageKey), Self.boolean(stored) == value else {
                error = "未能确认诊断设置已保存，请重试。"
                return
            }
        }
        captureBodies = value
        error = nil
    }

    private static func boolean(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
