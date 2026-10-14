import AppKit
import Darwin
import Foundation
import SwiftUI
import Virtualization

enum BrowserRuntimeState: Equatable {
    case idle, preparing, starting, booting, running, stopping, stopTimedOut
    var title: String {
        switch self {
        case .idle: "已停止"
        case .preparing: "正在验证镜像与准备资料盘…"
        case .starting: "正在启动虚拟机…"
        case .booting: "虚拟机已启动，等待 Firefox 窗口…"
        case .running: "Firefox 已就绪"
        case .stopping: "正在关闭浏览器并保存资料…"
        case .stopTimedOut: "关机尚未完成"
        }
    }
}

enum BrowserRuntimeFailure: Error, LocalizedError {
    case unavailable, fixture, start, configuration, channel, shutdown, shutdownTimedOut, readinessTimedOut
    var errorDescription: String? {
        switch self {
        case .unavailable: "此 Mac 不支持所需虚拟化功能。"
        case .fixture: "离线界面演示不会启动浏览器或访问真实资料盘。"
        case .start: "浏览器虚拟机未能启动，请检查镜像与 App 的虚拟化签名权限。"
        case .configuration: "浏览器虚拟机配置未通过校验。"
        case .channel: "浏览器网络通道未能创建。"
        case .shutdown: "无法请求 guest 正常关机；网络已关闭，资料盘仍保留。可重试停止或手动强制停止。"
        case .shutdownTimedOut: "guest 尚未完成关机；网络已关闭，App 保持打开。可继续等待，或手动强制停止。"
        case .readinessTimedOut: "尚未收到 Firefox 窗口就绪信号。可检查画面，或停止后重试。"
        }
    }
}

/// Recognizes only fixed guest lifecycle markers. Failure remains sticky even
/// if a conflicting completion marker follows it.
struct BrowserSerialMarkers {
    enum Marker: String {
        case ready = "BROWSER_SESSION_READY"
        case profileFailed = "BROWSER_PROFILE_FAILED"
        case configurationFailed = "BROWSER_CONFIG_FAILED"
        case sessionFailed = "BROWSER_SESSION_FAILED"
        case stopFailed = "BROWSER_SESSION_STOP_FAILED"
        case stopComplete = "BROWSER_SESSION_STOP_COMPLETE"
    }
    private var line = Data()
    private var discarding = false
    private(set) var wasReady = false
    private(set) var stopComplete = false
    private(set) var stopFailed = false
    private var readFailed = false

    mutating func invalidateStopConfirmation() { readFailed = true }

    mutating func consume(_ data: Data) -> [Marker] {
        var markers: [Marker] = []
        for byte in data {
            if byte == 10 {
                if line.last == 13 { line.removeLast() }
                if !discarding, let text = String(data: line, encoding: .utf8), let marker = Marker(rawValue: text) {
                    switch marker {
                    case .ready: wasReady = true; stopComplete = false
                    case .stopFailed: stopFailed = true
                    case .stopComplete: stopComplete = true
                    default: break
                    }
                    markers.append(marker)
                }
                line.removeAll(keepingCapacity: true); discarding = false
            } else if !discarding {
                if line.count < 128 { line.append(byte) }
                else { line.removeAll(keepingCapacity: true); discarding = true }
            }
        }
        return markers
    }

    func saveFailure(forced: Bool) -> String? {
        guard wasReady, !forced, stopFailed || readFailed || !stopComplete else { return nil }
        if readFailed { return "浏览器关闭确认未能完整读取。资料盘保留，最近的浏览器更改可能尚未保存。" }
        return stopFailed
            ? "Firefox 未完成正常保存确认。资料盘保留，最近的浏览器更改可能尚未保存。"
            : "未收到 Firefox 正常保存确认。资料盘保留，最近的浏览器更改可能尚未保存。"
    }
}

/// The App owns exactly one browser VM. Switching pages only changes its view.
/// All Virtualization calls use the main queue; disk validation runs separately.
@MainActor
final class BrowserVMController: NSObject, ObservableObject, VZVirtualMachineDelegate, VZVirtioSocketListenerDelegate, BrowserTerminationManaging {
    @Published private(set) var state: BrowserRuntimeState = .idle
    @Published private(set) var virtualMachine: VZVirtualMachine?
    @Published private(set) var firefoxVersion = "尚未验证"
    @Published private(set) var proxyURL = BrowserSettingsConfiguration.defaultConfiguration.proxyURL
    @Published var proxyDraft = BrowserSettingsConfiguration.defaultConfiguration.proxyURL
    @Published private(set) var resistFingerprinting = false
    @Published var resistFingerprintingDraft = false
    @Published private(set) var settingsStatus = "浏览器使用独立代理出口。"
    @Published private(set) var error: String?
    @Published private(set) var networkFailureCode: String?
    @Published private(set) var activeConnections = 0
    @Published private(set) var terminationSaveFailure: String?
    @Published private(set) var pasteInProgress = false
    @Published private(set) var pasteStatus: String?
    @Published private(set) var pasteFocusRequest = 0
    private let storage: BrowserRuntimeStorage
    private let settingsStore: BrowserSettingsStore
    private let fixtureOnly: Bool
    private var prepared: BrowserPreparedRuntime?
    private var preparation: Task<BrowserPreparedRuntime, Error>?
    private var launchTask: Task<Void, Never>?
    private var gateway: BrowserProxyGateway?
    private var listener: VZVirtioSocketListener?
    private var serialPipe: Pipe?
    private var serialMarkers = BrowserSerialMarkers()
    private var serialSource: DispatchSourceRead?
    private var serialDrainTask: Task<Void, Never>?
    private var shutdownTimer: Timer?
    private var readinessTimer: Timer?
    private var terminationAdmissionClosed = false
    private var stopRequested = false
    private var forceRequested = false
    private var shutdownRequested = false
    private var operationID = UUID()
    private var settingsValid = true
    private var pasteID: UUID?
    private var pendingPasteText: String?
    private var pasteConnectTimer: Timer?
    private var pasteConnection: VZVirtioSocketConnection?
    private var pasteTransport: BrowserClipboardTransport?
    private var pasteTask: Task<Void, Never>?

    init(storage: BrowserRuntimeStorage = BrowserRuntimeStorage(), settingsStore: BrowserSettingsStore = .init(), fixtureOnly: Bool = false) {
        self.storage = storage; self.settingsStore = settingsStore; self.fixtureOnly = fixtureOnly
        super.init()
        do {
            let saved = try settingsStore.load()
            proxyURL = saved.proxyURL; proxyDraft = saved.proxyURL
            resistFingerprinting = saved.resistFingerprinting; resistFingerprintingDraft = saved.resistFingerprinting
        } catch { self.error = error.localizedDescription; settingsValid = false }
    }

    var canStart: Bool { state == .idle && launchTask == nil && serialDrainTask == nil && pasteTask == nil && !terminationAdmissionClosed && !fixtureOnly && gateway == nil && settingsValid }
    var canConfigure: Bool { state == .idle && launchTask == nil && serialDrainTask == nil && pasteTask == nil && !terminationAdmissionClosed && gateway == nil }
    var canStop: Bool { state != .idle && state != .stopping }
    var canForceStop: Bool { state == .stopTimedOut }
    var isTerminationWorkSettled: Bool { state == .idle && launchTask == nil && virtualMachine == nil && gateway == nil && serialDrainTask == nil && pasteTask == nil }
    var canPasteText: Bool { state == .running && !stopRequested && !terminationAdmissionClosed && !pasteInProgress && pasteTask == nil }
    var proxyStatus: String {
        if let networkFailureCode {
            let recentBlock = "最近受阻 · \(networkFailureCode)"
            return activeConnections > 0 ? "代理活动连接：\(activeConnections) · \(recentBlock)" : recentBlock
        }
        if state == .stopping || state == .stopTimedOut { return "网络已关闭" }
        if state == .idle { return "已配置 · 启动后连接" }
        return activeConnections == 0 ? "等待浏览器代理请求" : "代理活动连接：\(activeConnections)"
    }

    func saveSettings() {
        guard canConfigure else { error = BrowserSettingsFailure.busy.localizedDescription; return }
        do {
            let value = BrowserSettingsConfiguration(proxyURL: proxyDraft, resistFingerprinting: resistFingerprintingDraft)
            try settingsStore.save(value)
            proxyURL = value.proxyURL; proxyDraft = value.proxyURL
            resistFingerprinting = value.resistFingerprinting; settingsValid = true
            settingsStatus = "已保存 · 下次启动浏览器时使用。"; error = terminationSaveFailure
        } catch { self.error = error.localizedDescription }
    }

    func clearProfile() {
        guard canConfigure else { error = BrowserSettingsFailure.busy.localizedDescription; return }
        do {
            try storage.clearProfile()
            terminationSaveFailure = nil
            settingsStatus = "浏览器资料已清除；下次启动使用新的资料盘。"; error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// The only production read of the host clipboard. Called by an explicit
    /// button/menu/Command-V action, never from a timer or a guest request.
    func pasteTextFromMac(readText: () -> String? = { NSPasteboard.general.string(forType: .string) }) {
        guard canPasteText, let machine = virtualMachine,
              let socket = machine.socketDevices.first as? VZVirtioSocketDevice else {
            pasteStatus = pasteInProgress ? "正在粘贴，请稍候。" : "请先启动 Firefox，再粘贴文本。"
            return
        }
        guard let text = readText() else { pasteStatus = "Mac 剪贴板中没有可粘贴的纯文本。"; return }
        do { try BrowserClipboardTransport.validate(text: text) }
        catch { pasteStatus = "文本为空、包含空字符或超过 64 KiB，无法粘贴。"; return }
        let id = UUID()
        pasteID = id; pendingPasteText = text; pasteInProgress = true
        pasteStatus = "正在粘贴…"; pasteFocusRequest += 1
        pasteConnectTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pasteID == id else { return }
                self.cancelPaste()
                self.pasteStatus = "粘贴通道连接超时。请确认 Firefox 已就绪后重试。"
            }
        }
        socket.connect(toPort: BrowserClipboardTransport.port) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.pasteID == id, self.virtualMachine === machine, self.state == .running else {
                    if case .success(let connection) = result { connection.close() }
                    return
                }
                self.pasteConnectTimer?.invalidate(); self.pasteConnectTimer = nil
                switch result {
                case .failure:
                    self.cancelPaste()
                    self.pasteStatus = "无法连接粘贴通道。请停止并重新启动 Firefox 后重试。"
                case .success(let connection):
                    guard let text = self.pendingPasteText else { connection.close(); self.cancelPaste(); return }
                    self.pendingPasteText = nil; self.pasteConnection = connection
                    self.pasteTask = Task { @MainActor in
                        defer {
                            connection.close()
                            self.objectWillChange.send()
                            self.pasteTask = nil
                            if self.pasteID == id {
                                self.pasteConnection = nil; self.pasteTransport = nil
                                self.pasteID = nil; self.pasteInProgress = false
                            }
                        }
                        guard self.pasteID == id, !Task.isCancelled else { return }
                        do {
                            let transport = try BrowserClipboardTransport()
                            self.pasteTransport = transport
                            let reply = try await transport.send(text: text, connection: connection)
                            guard self.pasteID == id else { return }
                            switch reply {
                            case .completed: self.pasteStatus = "已发送粘贴"
                            case .invalidPayload: self.pasteStatus = "Firefox 拒绝了文本格式，未粘贴。"
                            case .busy: self.pasteStatus = "Firefox 粘贴通道正忙，请稍后重试。"
                            case .firefoxNotFocused: self.pasteStatus = "请先点击 Firefox 中的输入位置，再粘贴。"
                            case .clipboardFailed: self.pasteStatus = "Firefox 未能读取临时文本，请重新选择输入位置后重试。"
                            case .guestTimeout: self.pasteStatus = "粘贴未完成。请松开快捷键，并确认输入位置后重试。"
                            }
                        } catch {
                            guard self.pasteID == id else { return }
                            self.pasteStatus = "粘贴未能确认完成，请检查 Firefox 中的输入内容后再决定是否重试。"
                        }
                    }
                }
            }
        }
    }

    private func cancelPaste() {
        pasteID = nil; pendingPasteText = nil
        pasteConnectTimer?.invalidate(); pasteConnectTimer = nil
        pasteTransport?.cancel(); pasteTask?.cancel()
        pasteConnection?.close(); pasteConnection = nil; pasteTransport = nil
        if pasteInProgress { pasteStatus = "粘贴已停止。" }
        pasteInProgress = false
    }

    func start() {
        guard canStart else {
            if fixtureOnly { error = BrowserRuntimeFailure.fixture.localizedDescription }
            return
        }
        guard VZVirtualMachine.isSupported else { error = BrowserRuntimeFailure.unavailable.localizedDescription; return }
        error = terminationSaveFailure; networkFailureCode = nil; activeConnections = 0; pasteStatus = nil
        stopRequested = false; forceRequested = false; shutdownRequested = false
        serialMarkers = BrowserSerialMarkers()
        operationID = UUID(); let id = operationID
        state = .preparing
        let storage = self.storage
        let resistFingerprinting = self.resistFingerprinting
        let preparation = Task.detached(priority: .userInitiated) { try storage.prepare(resistFingerprinting: resistFingerprinting) }
        self.preparation = preparation
        launchTask = Task { @MainActor in
            do {
                let ready = try await preparation.value
                self.preparation = nil
                self.prepared = ready
                self.firefoxVersion = ready.manifest.firefoxVersion
                if self.stopRequested || self.terminationAdmissionClosed {
                    self.finishStopped(); self.launchTask = nil; return
                }
                try self.createMachine(ready, operationID: id)
                self.launchTask = nil
            } catch {
                self.preparation = nil
                if !(error is CancellationError) { self.error = self.safeMessage(error) }
                self.finishStopped(); self.launchTask = nil
            }
        }
    }

    func stop() {
        guard state != .idle else { return }
        stopRequested = true
        disconnectNetwork()
        readinessTimer?.invalidate(); readinessTimer = nil
        if state == .preparing { preparation?.cancel(); state = .stopping; return }
        if state == .stopTimedOut && shutdownRequested { return }
        state = .stopping
        armShutdownDeadline()
        requestGuestShutdown()
    }

    /// Called only after the user confirms the risk to recent unsaved guest data.
    func forceStop() {
        guard virtualMachine != nil else { return }
        stopRequested = true; forceRequested = true
        disconnectNetwork(); readinessTimer?.invalidate(); shutdownTimer?.invalidate()
        state = .stopping
        forceStopMachine()
    }

    func beginTermination() { terminationAdmissionClosed = true; stop() }
    func endTermination() { terminationAdmissionClosed = false }
    func acknowledgeTerminationSaveFailure() throws {
        guard isTerminationWorkSettled else { throw BrowserRuntimeFailure.shutdown }
        terminationSaveFailure = nil
    }

    /// Exercises the production stopped-VM serial drain without creating a VM
    /// or accessing a profile. Only controllers explicitly created as fixtures
    /// can install this synthetic pipe.
    func finishStoppedFixture(serial: Pipe, forced: Bool = false) throws {
        guard fixtureOnly, isTerminationWorkSettled else { throw BrowserRuntimeFailure.fixture }
        let descriptor = serial.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw BrowserRuntimeFailure.channel }
        serialPipe = serial; serialMarkers = BrowserSerialMarkers(); forceRequested = forced
        state = .stopping
        finishStopped()
    }

    private func createMachine(_ runtime: BrowserPreparedRuntime, operationID: UUID) throws {
        let boot = VZLinuxBootLoader(kernelURL: runtime.kernelURL)
        boot.initialRamdiskURL = runtime.initrdURL
        boot.commandLine = "root=/dev/vda rw console=hvc0 apparmor=1 security=apparmor systemd.unified_cgroup_hierarchy=1 systemd.mask=systemd-networkd-wait-online.service"
        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = VZGenericPlatformConfiguration()
        configuration.bootLoader = boot
        configuration.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, min(2, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        configuration.memorySize = 3 * 1024 * 1024 * 1024
        configuration.networkDevices = []; configuration.directorySharingDevices = []
        configuration.audioDevices = []
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 800)]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.storageDevices = try [
            VZVirtioBlockDeviceConfiguration(attachment: VZDiskImageStorageDeviceAttachment(url: runtime.diskURL, readOnly: false)),
            VZVirtioBlockDeviceConfiguration(attachment: VZDiskImageStorageDeviceAttachment(url: runtime.profileDiskURL, readOnly: false)),
            VZVirtioBlockDeviceConfiguration(attachment: VZDiskImageStorageDeviceAttachment(url: runtime.configDiskURL, readOnly: true))
        ]
        let pipe = Pipe(); serialPipe = pipe
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw BrowserRuntimeFailure.channel }
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: pipe.fileHandleForWriting)
        configuration.serialPorts = [serial]
        do { try configuration.validate() } catch { throw BrowserRuntimeFailure.configuration }
        let gateway = try BrowserProxyGateway(proxyURL: proxyURL) { [weak self] event in
            Task { @MainActor in
                guard let self, self.operationID == operationID, self.gateway != nil else { return }
                self.activeConnections = event.activeCount
                if let failure = event.failure, failure != .stopped { self.networkFailureCode = failure.rawValue }
                self.finishGatewayIfSettled()
            }
        }
        self.gateway = gateway
        let machine = VZVirtualMachine(configuration: configuration)
        machine.delegate = self; virtualMachine = machine
        guard let socket = machine.socketDevices.first as? VZVirtioSocketDevice else { throw BrowserRuntimeFailure.channel }
        let listener = VZVirtioSocketListener(); listener.delegate = self; self.listener = listener
        socket.setSocketListener(listener, forPort: 40125)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        serialSource = source
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.operationID == operationID, self.serialPipe === pipe else { return }
                if self.drainSerial() { self.serialSource?.cancel() }
            }
        }
        source.resume()
        state = .starting
        machine.start { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.virtualMachine === machine, self.operationID == operationID else { return }
                switch result {
                case .success:
                    if self.forceRequested { self.forceStopMachine() }
                    else if self.stopRequested { self.requestGuestShutdown() }
                    else {
                        self.state = self.serialMarkers.wasReady ? .running : .booting
                        self.readinessTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
                            MainActor.assumeIsolated {
                                guard let self, self.operationID == operationID, self.state == .booting else { return }
                                self.error = BrowserRuntimeFailure.readinessTimedOut.localizedDescription
                            }
                        }
                    }
                case .failure:
                    self.error = BrowserRuntimeFailure.start.localizedDescription
                    self.finishStopped()
                }
            }
        }
    }

    nonisolated func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        MainActor.assumeIsolated {
            guard !stopRequested, !terminationAdmissionClosed, [.starting, .booting, .running].contains(state) else { return false }
            return gateway?.accept(connection) ?? false
        }
    }

    private func consumeSerial(_ data: Data) {
        for marker in serialMarkers.consume(data) {
            switch marker {
            case .ready:
                if !stopRequested {
                    if state == .booting || state == .starting {
                        state = .running; readinessTimer?.invalidate(); readinessTimer = nil; error = nil
                    }
                }
            case .profileFailed: error = "浏览器资料盘未能挂载。资料保留，请停止浏览器后检查资料盘。"
            case .configurationFailed: error = "浏览器设置未通过 guest 校验。请停止浏览器后重新保存设置。"
            case .sessionFailed:
                readinessTimer?.invalidate(); readinessTimer = nil
                error = "Firefox 窗口未能启动。浏览器资料保留，请停止后重试。"
            case .stopFailed: error = "Firefox 未完成正常保存确认。资料盘保留，最近的浏览器更改可能尚未保存。"
            case .stopComplete: break
            }
        }
    }

    /// Nonblocking, bounded reads keep serial delivery and VZ stop callbacks on
    /// one queue. Unknown console bytes are discarded by the fixed-marker parser.
    private func drainSerial() -> Bool {
        guard let pipe = serialPipe else { return true }
        var bytes = [UInt8](repeating: 0, count: 4_096)
        for _ in 0..<16 {
            let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count > 0 { consumeSerial(Data(bytes.prefix(count))) }
            else if count == 0 { return true }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return false }
            else {
                serialMarkers.invalidateStopConfirmation()
                error = "浏览器关闭串口未能排空，正常保存尚未确认。资料盘保留。"
                return true
            }
        }
        return false
    }

    private func disconnectNetwork() {
        cancelPaste()
        gateway?.closeAdmission(); gateway?.stop()
        listener?.delegate = nil
    }

    private func requestGuestShutdown() {
        guard let machine = virtualMachine else { return }
        if machine.state == .starting { return }
        if machine.state == .stopped || machine.state == .error { finishStopped(); return }
        guard !shutdownRequested else { return }
        guard machine.canRequestStop else {
            error = BrowserRuntimeFailure.shutdown.localizedDescription; state = .stopTimedOut; return
        }
        do { try machine.requestStop(); shutdownRequested = true }
        catch { self.error = BrowserRuntimeFailure.shutdown.localizedDescription; state = .stopTimedOut; return }
        state = .stopping
        armShutdownDeadline()
    }

    private func armShutdownDeadline() {
        shutdownTimer?.invalidate()
        let id = operationID
        shutdownTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.operationID == id, self.virtualMachine != nil else { return }
                self.state = .stopTimedOut; self.error = BrowserRuntimeFailure.shutdownTimedOut.localizedDescription
            }
        }
    }

    private func forceStopMachine() {
        guard let machine = virtualMachine else { return }
        if machine.state == .starting {
            state = .stopTimedOut
            error = "虚拟机仍在启动，强制停止已排队；启动完成后会立即停止。资料盘继续保留并独占。"
            return
        }
        if machine.state == .stopped || machine.state == .error { finishStopped(); return }
        guard machine.canStop else { state = .stopTimedOut; error = BrowserRuntimeFailure.shutdown.localizedDescription; return }
        machine.stop { [weak self] stopError in
            MainActor.assumeIsolated {
                guard let self, self.virtualMachine === machine else { return }
                if stopError == nil { self.finishStopped() }
                else { self.state = .stopTimedOut; self.error = BrowserRuntimeFailure.shutdown.localizedDescription }
            }
        }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated {
            guard self.virtualMachine === virtualMachine else { return }
            finishStopped()
        }
    }
    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated {
            guard self.virtualMachine === virtualMachine else { return }
            self.error = "浏览器虚拟机异常停止，资料盘已保留。最近的浏览器更改可能尚未保存。"
            finishStopped()
        }
    }

    private func finishStopped() {
        guard serialDrainTask == nil else { return }
        disconnectNetwork()
        shutdownTimer?.invalidate(); shutdownTimer = nil
        readinessTimer?.invalidate(); readinessTimer = nil
        listener = nil; virtualMachine?.delegate = nil; virtualMachine = nil
        serialSource?.cancel(); serialSource = nil
        if let pipe = serialPipe {
            do { try pipe.fileHandleForWriting.close() }
            catch {
                serialMarkers.invalidateStopConfirmation()
                self.error = "浏览器关闭串口未能结束，正常保存尚未确认。资料盘保留。"
            }
            if !drainSerial() {
                state = .stopping
                let id = operationID
                serialDrainTask = Task { @MainActor in
                    let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
                    var reachedEOF = self.drainSerial()
                    while self.operationID == id, !reachedEOF, ContinuousClock.now < deadline {
                        do { try await Task.sleep(for: .milliseconds(10)) }
                        catch {
                            self.serialMarkers.invalidateStopConfirmation()
                            self.error = "浏览器关闭确认读取被中断，正常保存尚未确认。资料盘保留。"; break
                        }
                        reachedEOF = self.drainSerial()
                    }
                    guard self.operationID == id else { return }
                    if !reachedEOF { self.serialMarkers.invalidateStopConfirmation() }
                    self.finalizeStopped()
                    self.serialDrainTask = nil
                }
                return
            }
        }
        finalizeStopped()
    }

    private func finalizeStopped() {
        serialPipe = nil
        if let failure = serialMarkers.saveFailure(forced: forceRequested) { terminationSaveFailure = failure }
        else if serialMarkers.wasReady || forceRequested { terminationSaveFailure = nil }
        if let terminationSaveFailure { error = terminationSaveFailure }
        else if forceRequested { error = "浏览器已强制停止，资料盘保留。最近的浏览器更改可能尚未保存。" }
        do { try prepared?.lease.release() }
        catch {
            let cleanupFailure = safeMessage(error)
            self.error = terminationSaveFailure.map { $0 + "\n" + cleanupFailure } ?? cleanupFailure
        }
        prepared = nil
        state = .idle
        finishGatewayIfSettled()
    }
    private func finishGatewayIfSettled() {
        if virtualMachine == nil, gateway?.isSettled == true { gateway = nil; activeConnections = 0 }
    }
    private func safeMessage(_ error: Error) -> String {
        if error is BrowserRuntimeFailure || error is BrowserSettingsFailure || error is BrowserRuntimeStorageFailure {
            return error.localizedDescription
        }
        return BrowserRuntimeFailure.start.localizedDescription
    }
}
