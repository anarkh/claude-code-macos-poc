import AppKit
import SwiftUI
import Virtualization

struct BrowserView: View {
    @ObservedObject var browser: BrowserVMController
    @State private var showingSettings = false
    @State private var confirmingForceStop = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("浏览器", systemImage: "globe").font(.system(size: 14, weight: .medium))
                Text(browser.state.title).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                    .accessibilityIdentifier("browser-state")
                Spacer(minLength: 12)
                Button("从 Mac 粘贴文本") { browser.pasteTextFromMac() }
                    .disabled(!browser.canPasteText)
                    .help("将 Mac 剪贴板中的纯文本粘贴到 Firefox（⌘V）")
                    .accessibilityIdentifier("browser-paste-text")
                if browser.state == .idle {
                    Button("启动 Firefox", action: browser.start).disabled(!browser.canStart)
                        .accessibilityIdentifier("browser-start")
                } else {
                    Button("停止", action: browser.stop).disabled(!browser.canStop)
                        .accessibilityIdentifier("browser-stop")
                }
                if browser.canForceStop {
                    Button("强制停止…") { confirmingForceStop = true }
                        .accessibilityIdentifier("browser-force-stop")
                }
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .help("浏览器设置").accessibilityIdentifier("browser-open-settings")
                    .accessibilityLabel("浏览器设置")
            }.padding(.horizontal, 24).frame(height: 54)
            Divider()
            if let status = browser.pasteStatus {
                Text(status).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.vertical, 6)
                    .accessibilityIdentifier("browser-paste-status")
            }
            if let error = browser.error {
                WorkbenchErrorLine(text: error).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .accessibilityIdentifier("browser-error")
            }
            if let machine = browser.virtualMachine {
                GeometryReader { area in
                    BrowserVirtualMachineSurface(machine: machine, pasteFocusRequest: browser.pasteFocusRequest,
                                                 onPaste: { browser.pasteTextFromMac() })
                        .frame(width: area.size.width, height: area.size.height)
                }.background(.black).accessibilityIdentifier("browser-vm-display")
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "globe").font(.system(size: 44, weight: .light))
                        .foregroundStyle(WorkbenchTheme.secondaryText)
                    Text("独立 Firefox 浏览器").font(.system(size: 20, weight: .medium))
                    Text("启动后可在 Firefox 地址栏中打开网站并手动登录。\n停止后保留浏览器资料，再次启动可继续使用。")
                        .font(.system(size: 13)).foregroundStyle(WorkbenchTheme.secondaryText)
                        .multilineTextAlignment(.center)
                    if browser.state == .preparing || browser.state == .stopping { ProgressView().controlSize(.small) }
                    else { Button("启动 Firefox", action: browser.start).disabled(!browser.canStart) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 16) {
                Text("Firefox \(browser.firefoxVersion)")
                Text(browser.resistFingerprinting ? "完整指纹保护 · UTC+0 / en-US" : "日语 · Asia/Tokyo")
                Spacer(minLength: 0)
                Text(browser.proxyStatus).lineLimit(1)
                    .accessibilityIdentifier("browser-proxy-status")
            }.font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
                .padding(.horizontal, 24).frame(height: 32)
        }.background(WorkbenchTheme.canvas)
            .sheet(isPresented: $showingSettings) {
                VStack(alignment: .trailing, spacing: 12) {
                    ScrollView { BrowserSettingsView(browser: browser) }
                    Button("完成") { showingSettings = false }.keyboardShortcut(.defaultAction)
                }.padding(24).frame(width: 540, height: 600)
            }
            .alert("强制停止浏览器？", isPresented: $confirmingForceStop) {
                Button("继续等待", role: .cancel) {}
                Button("强制停止", role: .destructive, action: browser.forceStop)
            } message: {
                Text("网络已经关闭。强制停止会中断 guest，最近的登录、书签或其他浏览器更改可能未保存；资料盘会保留。")
            }
            .accessibilityIdentifier("browser-workspace")
    }
}

private struct BrowserVirtualMachineSurface: NSViewRepresentable {
    let machine: VZVirtualMachine
    let pasteFocusRequest: Int
    let onPaste: () -> Void
    func makeNSView(context: Context) -> BrowserVirtualMachineView {
        let view = BrowserVirtualMachineView()
        view.automaticallyReconfiguresDisplay = true
        view.capturesSystemKeys = true
        view.virtualMachine = machine
        view.onPasteFromMac = onPaste
        view.lastPasteFocusRequest = pasteFocusRequest
        return view
    }
    func updateNSView(_ view: BrowserVirtualMachineView, context: Context) {
        view.automaticallyReconfiguresDisplay = true
        view.onPasteFromMac = onPaste
        if view.virtualMachine !== machine { view.virtualMachine = machine }
        if view.lastPasteFocusRequest != pasteFocusRequest {
            view.lastPasteFocusRequest = pasteFocusRequest
            view.window?.makeFirstResponder(view)
        }
    }
    static func dismantleNSView(_ view: BrowserVirtualMachineView, coordinator: ()) {
        view.onPasteFromMac = nil; view.virtualMachine = nil
    }
}

/// Scope Command-V to the VM display so native text fields elsewhere in the
/// workbench retain ordinary macOS paste. Control-V stays inside the guest.
final class BrowserVirtualMachineView: VZVirtualMachineView {
    var onPasteFromMac: (() -> Void)?
    var lastPasteFocusRequest = 0

    static func isHostPaste(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let focused = window?.firstResponder
        let hasFocus = focused === self || (focused as? NSView)?.isDescendant(of: self) == true
        if hasFocus && Self.isHostPaste(event) {
            if !event.isARepeat { onPasteFromMac?() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if Self.isHostPaste(event) {
            if !event.isARepeat { onPasteFromMac?() }
        } else { super.keyDown(with: event) }
    }

    @objc func paste(_ sender: Any?) { onPasteFromMac?() }
}
