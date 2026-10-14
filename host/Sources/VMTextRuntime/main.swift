import Darwin
import Foundation
import Virtualization

enum RuntimeError: Error {
    case invalid(String)
}

// The only host/guest channel accepts bounded JSON objects; it is never a socket
// forwarder, host file service, shell, or arbitrary provider transport.
final class TextPump: @unchecked Sendable {
    static let maxFrame = 1024 * 1024
    static let maxStream = 32 * 1024 * 1024
    let descriptor: Int32
    let lock = NSLock()
    var stopped = false
    var resultSeen = false
    let completion: @Sendable (String, Bool) -> Void

    init(descriptor: Int32, completion: @escaping @Sendable (String, Bool) -> Void) {
        self.descriptor = descriptor
        self.completion = completion
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            transfer(from: STDIN_FILENO, to: descriptor, guestToHost: false)
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            transfer(from: descriptor, to: STDOUT_FILENO, guestToHost: true)
        }
    }

    func stop(_ reason: String) {
        let value: Bool? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            return resultSeen
        }
        if let value { completion(reason, value) }
    }

    private func transfer(from source: Int32, to destination: Int32, guestToHost: Bool) {
        var partial = Data()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let allowed: Set<String> = guestToHost
            ? ["ready", "native_init", "provider_request", "result", "privacy", "runtime_error"]
            : ["start", "provider_response", "provider_chunk", "provider_end", "cancel"]
        while !lock.withLock({ stopped }) {
            let count = Darwin.read(source, &buffer, buffer.count)
            if count == 0 {
                stop(partial.isEmpty ? (guestToHost ? "guest_eof" : "stdin_eof") : "truncated_frame")
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
                stop("channel_read_failed"); return
            }
            total += count
            guard total <= Self.maxStream else { stop("stream_limit"); return }
            partial.append(contentsOf: buffer.prefix(count))
            while let newline = partial.firstIndex(of: 10) {
                let frame = Data(partial[..<newline])
                partial.removeSubrange(...newline)
                guard frame.count > 0, frame.count <= Self.maxFrame,
                      let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                      let kind = object["kind"] as? String, allowed.contains(kind) else {
                    stop("invalid_frame"); return
                }
                if guestToHost, kind == "result" { lock.withLock { resultSeen = true } }
                var line = frame
                line.append(10)
                let written = line.withUnsafeBytes { bytes -> Bool in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.write(destination, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if count < 0 {
                            if errno == EINTR { continue }
                            return false
                        }
                        if count == 0 { return false }
                        offset += count
                    }
                    return true
                }
                guard written else { stop("channel_write_failed"); return }
            }
            guard partial.count <= Self.maxFrame else { stop("frame_limit"); return }
        }
    }

    deinit { _ = Darwin.close(descriptor) }
}

@MainActor
final class TextRuntime: NSObject, @preconcurrency VZVirtualMachineDelegate, @preconcurrency VZVirtioSocketListenerDelegate {
    static let port: UInt32 = 40124
    var vm: VZVirtualMachine?
    var deadline: Timer?
    var listener: VZVirtioSocketListener?
    var connection: VZVirtioSocketConnection?
    var pump: TextPump?
    var signals: [DispatchSourceSignal] = []
    var finished = false
    var accepted = false
    var preparation = false
    var pendingStop: (Int32, String)?

    func emit(_ object: [String: Any], stdout: Bool = false) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { exit(2) }
        let target = stdout ? FileHandle.standardOutput : FileHandle.standardError
        target.write(data)
        target.write(Data([10]))
    }

    func start(_ args: [String]) throws {
        if args == ["preflight"] {
            emit(["kind": "vm_preflight", "virtualization_supported": VZVirtualMachine.isSupported,
                  "network_devices": 0, "host_directory_shares": 0], stdout: true)
            exit(VZVirtualMachine.isSupported ? 0 : 2)
        }
        guard (args.count == 5 || args.count == 6), args[0] == "boot",
              let timeout = Double(args[4]), timeout >= 30, timeout <= 600,
              args.count == 5 || args[5] == "prepare" else {
            throw RuntimeError.invalid("arguments")
        }
        guard VZVirtualMachine.isSupported else { throw RuntimeError.invalid("virtualization_unavailable") }
        preparation = args.count == 6
        let directory = URL(fileURLWithPath: args[1], isDirectory: true)
        let kernel = directory.appendingPathComponent("kernel")
        let initrd = directory.appendingPathComponent("initrd")
        let disk = directory.appendingPathComponent("guest.raw")
        let seed = URL(fileURLWithPath: args[2])
        let log = URL(fileURLWithPath: args[3])
        for file in [kernel, initrd, disk, seed] {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw RuntimeError.invalid("input_file") }
        }
        guard !FileManager.default.fileExists(atPath: log.path),
              FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RuntimeError.invalid("serial_log")
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
        config.socketDevices = preparation ? [] : [VZVirtioSocketDeviceConfiguration()]
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: try FileHandle(forWritingTo: log))
        config.serialPorts = [serial]
        config.storageDevices = try [
            VZVirtioBlockDeviceConfiguration(attachment: VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)),
            VZVirtioBlockDeviceConfiguration(attachment: VZDiskImageStorageDeviceAttachment(url: seed, readOnly: true))
        ]
        try config.validate()
        installSignals()
        emit(["kind": "vm_config", "network_devices": config.networkDevices.count,
              "host_directory_shares": config.directorySharingDevices.count,
              "directory_shares": config.directorySharingDevices.count,
              "clipboard_devices": 0, "graphics_devices": config.graphicsDevices.count,
              "socket_devices": config.socketDevices.count, "cpu_count": config.cpuCount,
              "memory_bytes": config.memorySize, "disposable_disk": true,
              "vsock_port": preparation ? 0 : Self.port], stdout: !preparation)
        let machine = VZVirtualMachine(configuration: config)
        machine.delegate = self
        vm = machine
        if !preparation {
            guard let socket = machine.socketDevices.first as? VZVirtioSocketDevice else { throw RuntimeError.invalid("vsock_unavailable") }
            let listener = VZVirtioSocketListener()
            listener.delegate = self
            self.listener = listener
            socket.setSocketListener(listener, forPort: Self.port)
        }
        deadline = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(code: 3, reason: "timeout") }
        }
        machine.start { result in
            MainActor.assumeIsolated {
                switch result {
                case .success:
                    self.emit(["kind": "vm_started"])
                    if let (code, reason) = self.pendingStop { self.stop(code: code, reason: reason) }
                case .failure: self.stop(code: 2, reason: "vm_start_failed")
                }
            }
        }
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        guard !finished, !accepted, connection.destinationPort == Self.port, connection.fileDescriptor >= 0 else { return false }
        let fd = Darwin.dup(connection.fileDescriptor)
        guard fd >= 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            if fd >= 0 { _ = Darwin.close(fd) }
            return false
        }
        var flag: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            _ = Darwin.close(fd); return false
        }
        accepted = true
        self.connection = connection
        let pump = TextPump(descriptor: fd) { [weak self] reason, resultSeen in
            Task { @MainActor in
                self?.stop(code: resultSeen && ["guest_eof", "stdin_eof"].contains(reason) ? 0 : 2, reason: reason)
            }
        }
        self.pump = pump
        pump.start()
        emit(["kind": "vm_channel_connected", "port": Self.port, "max_frame_bytes": TextPump.maxFrame])
        return true
    }

    private func installSignals() {
        for number in [SIGINT, SIGTERM] {
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.stop(code: 128 + number, reason: "host_signal") }
            }
            signals.append(source)
            source.resume()
        }
        Darwin.signal(SIGPIPE, SIG_IGN)
    }

    func stop(code: Int32, reason: String) {
        guard !finished else { return }
        if vm?.state == .starting {
            pendingStop = (code, reason)
            deadline?.invalidate()
            emit(["kind": "vm_stop_pending", "reason": reason])
            return
        }
        finished = true
        deadline?.invalidate()
        pump?.stop(reason)
        connection?.close()
        listener?.delegate = nil
        guard let vm, vm.state != .stopped else {
            emit(["kind": "vm_stopped", "reason": reason, "exit_code": code]); exit(code)
        }
        vm.stop { result in
            MainActor.assumeIsolated {
                if result == nil {
                    self.emit(["kind": "vm_stopped", "reason": reason, "exit_code": code]); exit(code)
                } else {
                    self.emit(["kind": "vm_stop_failed", "reason": reason]); exit(2)
                }
            }
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        stop(code: preparation || pump?.lock.withLock({ pump?.resultSeen ?? false }) == true ? 0 : 2, reason: "guest_poweroff")
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        stop(code: 2, reason: "vm_failed")
    }
}

let runner = TextRuntime()
do {
    try runner.start(Array(CommandLine.arguments.dropFirst()))
    RunLoop.main.run()
} catch {
    runner.emit(["kind": "vm_error", "error_code": "configuration_failed"])
    exit(2)
}
