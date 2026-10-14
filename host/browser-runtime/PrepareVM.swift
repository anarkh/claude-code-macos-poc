import Foundation
import Virtualization
import Darwin
import CryptoKit
import AppKit

final class PublicArtifactReceiver: @unchecked Sendable {
    let descriptor: Int32
    let directory: URL
    init(_ descriptor: Int32, _ directory: URL) { self.descriptor = descriptor; self.directory = directory }
    func start() {
        DispatchQueue.global().async { [self] in
            defer { _ = Darwin.close(descriptor) }
            do {
                var header = Data()
                var byte: UInt8 = 0
                while header.count < 1024 {
                    guard Darwin.read(descriptor, &byte, 1) == 1 else { throw NSError(domain: "ArtifactHeader", code: 1) }
                    if byte == 10 { break }
                    header.append(byte)
                }
                guard header.count < 1024,
                      let object = try JSONSerialization.jsonObject(with: header) as? [String: Any],
                      Set(object.keys) == Set(["schema", "name", "bytes", "sha256"]),
                      object["schema"] as? String == "browser-public-artifact/v1",
                      let name = object["name"] as? String, ["kernel", "initrd"].contains(name),
                      let bytes = object["bytes"] as? Int, bytes > 0, bytes <= 256 * 1024 * 1024,
                      let expected = object["sha256"] as? String, expected.count == 64 else {
                    throw NSError(domain: "ArtifactHeader", code: 2)
                }
                let target = directory.appendingPathComponent(name)
                guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw NSError(domain: "ArtifactOutput", code: 1)
                }
                let file = try FileHandle(forWritingTo: target)
                defer {
                    do { try file.close() }
                    catch { fputs("Public artifact close failed: \(error)\n", stderr) }
                }
                var hash = SHA256()
                var remaining = bytes
                var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
                while remaining > 0 {
                    let count = Darwin.read(descriptor, &buffer, min(buffer.count, remaining))
                    guard count > 0 else { throw NSError(domain: "ArtifactTruncated", code: 1) }
                    let data = Data(buffer.prefix(count))
                    try file.write(contentsOf: data)
                    hash.update(data: data)
                    remaining -= count
                }
                try file.synchronize()
                let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
                guard actual == expected else { throw NSError(domain: "ArtifactDigest", code: 1) }
                _ = Darwin.write(descriptor, "OK\n", 3)
                print("BROWSER_PUBLIC_ARTIFACT_RECEIVED name=\(name) bytes=\(bytes) sha256=\(actual)")
            } catch { fputs("Public artifact receiver: \(error)\n", stderr) }
        }
    }
}

// A disposable build/verification runner. NAT is available only in `prepare`
// mode; the production app does not invoke this runner or attach a NIC.
@MainActor
final class PrepareVM: NSObject, @preconcurrency VZVirtualMachineDelegate, @preconcurrency VZVirtioSocketListenerDelegate {
    var machine: VZVirtualMachine?
    var timer: Timer?
    var monitor: Timer?
    var window: NSWindow?
    var stopRequested = false
    var finished = false
    var artifactListener: VZVirtioSocketListener?
    var artifactConnections: [VZVirtioSocketConnection] = []
    var artifactDirectory: URL?
    var shutdownReadyAt: Date?

    func start(_ arguments: [String]) throws {
        guard arguments.count == 4, ["check", "prepare", "verify", "verify-short", "verify-shutdown", "verify-shutdown-full"].contains(arguments[0]),
              let timeout = Double(arguments[3]), timeout >= 30, timeout <= 3600 else {
            throw NSError(domain: "BrowserPreparation", code: 1)
        }
        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let log = URL(fileURLWithPath: arguments[2])
        guard !FileManager.default.fileExists(atPath: log.path),
              FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "BrowserPreparation", code: 2)
        }
        let loader = VZLinuxBootLoader(kernelURL: directory.appendingPathComponent("kernel"))
        loader.initialRamdiskURL = directory.appendingPathComponent("initrd")
        loader.commandLine = "root=/dev/vda rw console=hvc0 apparmor=1 security=apparmor systemd.unified_cgroup_hierarchy=1 systemd.mask=systemd-networkd-wait-online.service"
        loader.commandLine += " systemd.clock-usec=\(UInt64(Date().timeIntervalSince1970 * 1_000_000))"
        if arguments[0] == "verify" || arguments[0] == "verify-short" { loader.commandLine += " browser.verify=1" }
        if arguments[0] == "verify-short" { loader.commandLine += " browser.verify_short=1" }
        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = VZGenericPlatformConfiguration()
        configuration.bootLoader = loader
        configuration.cpuCount = min(2, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        configuration.memorySize = 3 * 1024 * 1024 * 1024
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.directorySharingDevices = []
        configuration.networkDevices = []
        if arguments[0] == "prepare" {
            let device = VZVirtioNetworkDeviceConfiguration()
            device.attachment = VZNATNetworkDeviceAttachment()
            configuration.networkDevices = [device]
        }
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 800)]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: try FileHandle(forWritingTo: log))
        configuration.serialPorts = [serial]
        configuration.storageDevices = [
            try VZVirtioBlockDeviceConfiguration(attachment: VZDiskImageStorageDeviceAttachment(url: directory.appendingPathComponent("guest.raw"), readOnly: false)),
            try VZVirtioBlockDeviceConfiguration(attachment: VZDiskImageStorageDeviceAttachment(url: directory.appendingPathComponent("profile.raw"), readOnly: false))
        ]
        let seed = directory.appendingPathComponent("seed.iso")
        configuration.storageDevices.append(try VZVirtioBlockDeviceConfiguration(attachment:
            VZDiskImageStorageDeviceAttachment(url: seed, readOnly: true)))
        try configuration.validate()
        let machine = VZVirtualMachine(configuration: configuration)
        machine.delegate = self
        self.machine = machine
        if arguments[0].hasPrefix("verify") {
            NSApplication.shared.setActivationPolicy(.accessory)
            let view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
            view.virtualMachine = machine
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Disposable Firefox VM verification"
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            self.window = window
            monitor = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard !self.stopRequested else { return }
                    do {
                        let data = try Data(contentsOf: log)
                        // A serial write may end within a UTF-8 code point;
                        // retain its bytes and inspect again after the next write.
                        let output = String(decoding: data, as: UTF8.self)
                        let shutdownOnly = arguments[0].hasPrefix("verify-shutdown")
                        if shutdownOnly && output.contains("BROWSER_SESSION_READY") && self.shutdownReadyAt == nil {
                            self.shutdownReadyAt = Date()
                            print("BROWSER_SHUTDOWN_VIEW_READY")
                        }
                        let duration: TimeInterval = arguments[0] == "verify-shutdown-full" ? 150 : 8
                        let shutdownDue = shutdownOnly && self.shutdownReadyAt.map { Date().timeIntervalSince($0) >= duration } == true
                        guard output.contains("BROWSER_SESSION_FAILED") || output.contains("BROWSER_ACPI_STOP_READY") || shutdownDue else { return }
                        self.stopRequested = true
                        guard let active = self.machine else { throw NSError(domain: "BrowserACPI", code: 1) }
                        try active.requestStop()
                        print("BROWSER_BUILD_ACPI_STOP_REQUESTED")
                    } catch { fputs("Browser verification monitor failed: \(error)\n", stderr); self.finish(2) }
                }
            }
        }
        if arguments[0] == "prepare" {
            let directory = directory.appendingPathComponent("exports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            artifactDirectory = directory
            let listener = VZVirtioSocketListener()
            listener.delegate = self
            artifactListener = listener
            guard let socket = machine.socketDevices.first as? VZVirtioSocketDevice else { throw NSError(domain: "ArtifactSocket", code: 1) }
            socket.setSocketListener(listener, forPort: 40126)
        }
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            MainActor.assumeIsolated { self.finish(3) }
        }
        machine.start { result in
            MainActor.assumeIsolated {
                switch result {
                case .success: print("BROWSER_BUILD_VM_STARTED mode=\(arguments[0])")
                case .failure(let error): fputs("\(error)\n", stderr); self.finish(2)
                }
            }
        }
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        guard artifactConnections.count < 2, connection.destinationPort == 40126, let artifactDirectory else { return false }
        let descriptor = Darwin.dup(connection.fileDescriptor)
        guard descriptor >= 0 else { return false }
        artifactConnections.append(connection)
        PublicArtifactReceiver(descriptor, artifactDirectory).start()
        return true
    }

    func finish(_ code: Int32) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        monitor?.invalidate()
        guard let machine, machine.state != .stopped else { exit(code) }
        machine.stop { error in
            if let error { fputs("\(error)\n", stderr); exit(2) }
            exit(code)
        }
    }
    func guestDidStop(_ virtualMachine: VZVirtualMachine) { finish(0) }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        fputs("\(error)\n", stderr); finish(2)
    }
}

MainActor.assumeIsolated {
    let runner = PrepareVM()
    do {
        try runner.start(Array(CommandLine.arguments.dropFirst()))
        RunLoop.main.run()
    } catch { fputs("\(error)\n", stderr); exit(2) }
}
