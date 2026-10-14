import Darwin
import Foundation
import Virtualization

enum PoCError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let s): return s } }
}

@MainActor
// VZ is created on its default main queue; delegate actor checks remain enabled.
final class Runner: NSObject, @preconcurrency VZVirtualMachineDelegate {
    var vm: VZVirtualMachine?
    var deadline: Timer?
    var finished = false
    var transport: VsockBridgeTransport?
    var signalSources: [DispatchSourceSignal] = []

    func printJSON(_ value: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("JSON evidence serialization failed: \(error)\n".utf8))
            exit(2)
        }
    }

    func start(_ args: [String]) throws {
        if args == ["preflight"] {
            printJSON(["kind": "host_preflight", "virtualization_supported": VZVirtualMachine.isSupported,
                       "os": ProcessInfo.processInfo.operatingSystemVersionString,
                       "architecture": "arm64", "nic_count": 0, "host_directory_shares": 0])
            exit(VZVirtualMachine.isSupported ? 0 : 2)
        }
        guard (args.count == 5 || args.count == 6), args[0] == "boot", let timeout = Double(args[4]), timeout >= 30, timeout <= 600 else {
            throw PoCError.invalid("usage: vm-poc preflight | boot IMAGE_DIRECTORY SEED_ISO SERIAL_LOG TIMEOUT_SECONDS [FAKE_RELAY_TRANSPORT_CONFIG]")
        }
        guard VZVirtualMachine.isSupported else { throw PoCError.invalid("Virtualization.framework is unavailable") }
        let transportConfiguration = args.count == 6 ? try VsockTransportConfiguration.load(path: args[5]) : nil
        let images = URL(fileURLWithPath: args[1], isDirectory: true)
        let kernel = images.appendingPathComponent("kernel")
        let initrd = images.appendingPathComponent("initrd")
        let disk = images.appendingPathComponent("guest.raw")
        let seed = URL(fileURLWithPath: args[2])
        let log = URL(fileURLWithPath: args[3])
        for url in [kernel, initrd, disk, seed] {
            guard FileManager.default.fileExists(atPath: url.path) else { throw PoCError.invalid("missing input: \(url.lastPathComponent)") }
        }
        guard !FileManager.default.fileExists(atPath: log.path) else { throw PoCError.invalid("serial log must be a new file") }
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw PoCError.invalid("cannot create serial log")
        }
        let boot = VZLinuxBootLoader(kernelURL: kernel)
        boot.initialRamdiskURL = initrd
        boot.commandLine = "root=/dev/vda rw console=hvc0 apparmor=1 security=apparmor systemd.unified_cgroup_hierarchy=1 systemd.mask=systemd-networkd-wait-online.service"
        let config = VZVirtualMachineConfiguration()
        config.platform = VZGenericPlatformConfiguration()
        config.bootLoader = boot
        config.cpuCount = min(2, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        config.memorySize = 2 * 1024 * 1024 * 1024
        config.networkDevices = []
        config.directorySharingDevices = []
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: try FileHandle(forWritingTo: log))
        config.serialPorts = [serial]
        config.storageDevices = try [
            VZVirtioBlockDeviceConfiguration(attachment: VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)),
            VZVirtioBlockDeviceConfiguration(attachment: VZDiskImageStorageDeviceAttachment(url: seed, readOnly: true))
        ]
        try config.validate()
        printJSON(["kind": "vm_config_validated", "nic_count": config.networkDevices.count,
                   "host_directory_shares": config.directorySharingDevices.count,
                   "socket_device_count": config.socketDevices.count,
                   "cpu_count": config.cpuCount, "memory_bytes": config.memorySize])
        let machine = VZVirtualMachine(configuration: config)
        machine.delegate = self
        self.vm = machine
        if let transportConfiguration {
            guard let socketDevice = machine.socketDevices.first as? VZVirtioSocketDevice else {
                throw PoCError.invalid("the configured virtio socket device is unavailable")
            }
            let bridge = VsockBridgeTransport(configuration: transportConfiguration, device: socketDevice) { [weak self] event in
                self?.printJSON(event)
            }
            transport = bridge
            bridge.register()
        }
        installSignalHandlers()
        deadline = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.finished, let vm = self.vm else { return }
                self.printJSON(["kind": "timeout", "state": vm.state.rawValue])
                self.stopAndExit(code: 3, reason: "timeout")
            }
        }
        machine.start { result in
            MainActor.assumeIsolated {
                switch result {
                case .success: self.printJSON(["kind": "vm_started"])
                case .failure(let error):
                    self.printJSON(["kind": "vm_start_failed", "error": error.localizedDescription])
                    self.finishAndExit(code: 2, reason: "start_failure")
                }
            }
        }
    }

    private func installSignalHandlers() {
        for number in [SIGINT, SIGTERM] {
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.finished else { return }
                    self.printJSON(["kind": "host_signal", "signal": number])
                    self.stopAndExit(code: 128 + number, reason: "host_signal")
                }
            }
            signalSources.append(source)
            source.resume()
        }
    }

    func cleanupTransport(reason: String, completion: @escaping () -> Void) {
        if let transport { transport.shutdown(reason: reason, completion: completion) }
        else { completion() }
    }

    private func stopAndExit(code: Int32, reason: String) {
        finished = true
        deadline?.invalidate()
        cleanupTransport(reason: reason) { [self] in
            guard let vm else { exit(code) }
            vm.stop { result in
                MainActor.assumeIsolated {
                    self.printJSON(["kind": "forced_vm_stop", "result": String(describing: result)])
                    exit(code)
                }
            }
        }
    }

    private func finishAndExit(code: Int32, reason: String) {
        finished = true
        deadline?.invalidate()
        cleanupTransport(reason: reason) { exit(code) }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        guard !finished else { return }
        printJSON(["kind": "guest_stopped", "state": virtualMachine.state.rawValue])
        finishAndExit(code: 0, reason: "guest_stop")
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        guard !finished else { return }
        printJSON(["kind": "vm_failed", "error": error.localizedDescription])
        finishAndExit(code: 2, reason: "vm_error")
    }
}

let runner = Runner()
do {
    try runner.start(Array(CommandLine.arguments.dropFirst()))
    RunLoop.main.run()
} catch {
    runner.printJSON(["kind": "host_error", "error": String(describing: error)])
    runner.cleanupTransport(reason: "host_error") { exit(2) }
    RunLoop.main.run()
}
