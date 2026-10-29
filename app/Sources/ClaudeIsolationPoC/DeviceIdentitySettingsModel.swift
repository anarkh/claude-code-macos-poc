import Foundation
import SwiftUI

@MainActor
final class DeviceIdentitySettingsModel: ObservableObject {
    @Published private(set) var deviceID: String?
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    private let store: any InstallationIdentityManaging

    init(store: any InstallationIdentityManaging) { self.store = store }

    func refresh() {
        status = nil
        do {
            deviceID = try store.loadDeviceID()
            error = nil
        } catch {
            deviceID = nil
            self.error = (error as? InstallationIdentityFailure)?.errorDescription
                ?? "无法读取设备 ID，请检查 App 数据目录权限。"
        }
    }

    func replaceDeviceID(isAllowed: Bool) {
        status = nil
        guard isAllowed else {
            error = "正在执行请求或维护任务，请等待完成后再更换设备 ID。"
            return
        }
        do {
            deviceID = try store.replaceDeviceID()
            status = "已更换设备 ID，下次 Claude 订阅请求将使用新 ID。"
            error = nil
        } catch {
            // A write may have completed before readback failed. Do not keep
            // displaying an old identity as though it were still authoritative.
            deviceID = nil
            self.error = (error as? InstallationIdentityFailure)?.errorDescription
                ?? "未能确认设备 ID 已更换，请检查 App 数据目录权限后重试。"
        }
    }
}
