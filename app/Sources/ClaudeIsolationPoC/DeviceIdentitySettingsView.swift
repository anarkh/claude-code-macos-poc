import SwiftUI

struct DeviceIdentitySettingsView: View {
    @ObservedObject var model: DeviceIdentitySettingsModel
    let canReplace: Bool
    let replace: () -> Void
    @State private var confirmingReplacement = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("设备身份").font(.system(size: 14, weight: .semibold))
            Text("设备 ID 在本机固定保存，新建对话只更换会话 ID。需要切换设备身份时，可手动生成新的设备 ID。")
                .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
            if let deviceID = model.deviceID {
                Text("当前设备 ID：\(deviceID.prefix(8))…\(deviceID.suffix(8))")
                    .font(.system(size: 12, design: .monospaced))
                    .accessibilityIdentifier("device-identity-current")
            } else if model.error == nil {
                Text("尚未生成设备 ID；首次订阅请求时会自动创建。")
                    .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            Button("更换设备 ID…") { confirmingReplacement = true }
                .disabled(!canReplace)
                .accessibilityIdentifier("replace-device-identity")
            if !canReplace {
                Text("请等待当前请求或维护任务完成后再更换。")
                    .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
            }
            if let status = model.status {
                Text(status).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                    .accessibilityIdentifier("device-identity-status")
            }
            if let error = model.error { WorkbenchErrorLine(text: error) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refresh() }
        .alert("更换本机设备 ID？", isPresented: $confirmingReplacement) {
            Button("取消", role: .cancel) {}
            Button("更换设备 ID", action: replace)
        } message: {
            Text("将生成新的随机设备 ID，供后续 Claude 订阅请求使用。已有对话继续使用原会话 ID；登录凭据和历史记录会保留。")
        }
    }
}
