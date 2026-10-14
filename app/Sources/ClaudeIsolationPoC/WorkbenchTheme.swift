import AppKit
import SwiftUI

enum WorkbenchTheme {
    static let sidebarWidth: CGFloat = 208
    static let contentWidth: CGFloat = 860
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let sidebar = adaptiveColor(light: 0xFAFAFA, dark: 0x181818)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let editor = Color(nsColor: .textBackgroundColor)
    static let secondaryText = Color(nsColor: .labelColor).opacity(0.78)
    static let selection = adaptiveColor(light: 0xEDEDED, dark: 0x303030)
    static let border = Color(nsColor: .separatorColor).opacity(0.65)
    static let subtleFill = Color.primary.opacity(0.055)
    static let codeFill = Color.primary.opacity(0.035)

    private static func adaptiveColor(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                           green: CGFloat((rgb >> 8) & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        })
    }
}

struct WorkbenchErrorLine: View {
    let text: String
    var body: some View {
        Label {
            Text(text).foregroundStyle(WorkbenchTheme.secondaryText)
        } icon: {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true).accessibilityLabel("错误：\(text)")
    }
}

struct WorkbenchTextEditor: View {
    @Binding var text: String
    let placeholder: String
    let identifier: String
    let minimumHeight: CGFloat
    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text).font(.system(size: 14)).scrollContentBackground(.hidden).padding(10)
                .accessibilityIdentifier(identifier).accessibilityLabel(placeholder)
            if text.isEmpty {
                Text(placeholder).font(.system(size: 14)).foregroundStyle(WorkbenchTheme.secondaryText)
                    .padding(.horizontal, 15).padding(.vertical, 18).allowsHitTesting(false)
            }
        }
        .frame(minHeight: minimumHeight)
        .background(WorkbenchTheme.editor, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(WorkbenchTheme.border, lineWidth: 1))
    }
}
