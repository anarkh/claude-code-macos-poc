import CoreFoundation
import Darwin
import Foundation
import Virtualization

struct VsockTransportConfiguration: Sendable {
    static let port: UInt32 = 40123
    let gatewaySocketPath: String
    let sessionID: UUID
    let bootEpoch: Int64

    static func load(path: String) throws -> Self {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw PoCError.invalid("transport config must be an absolute local file")
        }
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw PoCError.invalid("cannot open private transport config") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_mode & 0o7777 == 0o600,
              metadata.st_nlink == 1, metadata.st_size > 0, metadata.st_size <= 8192 else {
            throw PoCError.invalid("transport config requires a current-user regular 0600 file")
        }
        let data = try file.read(upToCount: 8193) ?? Data()
        try file.close()
        guard data.count <= 8192,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schema", "gateway_socket_path", "vsock_port", "session_id", "boot_epoch"]),
              object["schema"] as? String == "vsock-transport-fixture/v1",
              let socketPath = object["gateway_socket_path"] as? String,
              let portNumber = object["vsock_port"] as? NSNumber,
              CFGetTypeID(portNumber) != CFBooleanGetTypeID(), portNumber.doubleValue == Double(port),
              let session = object["session_id"] as? String, let sessionID = UUID(uuidString: session),
              let epoch = object["boot_epoch"] as? NSNumber,
              CFGetTypeID(epoch) != CFBooleanGetTypeID(), epoch.int64Value > 0,
              epoch.doubleValue == Double(epoch.int64Value) else {
            throw PoCError.invalid("invalid fixed fake-fixture transport schema")
        }
        try validateGatewaySocket(path: socketPath)
        return Self(gatewaySocketPath: socketPath, sessionID: sessionID, bootEpoch: epoch.int64Value)
    }

    static func validateGatewaySocket(path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              components.count >= 3,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              components.last == "gateway.sock",
              path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw PoCError.invalid("gateway must be the fixed private gateway.sock endpoint")
        }
        // Foundation standardization maps existing /private/tmp sockets to /tmp.
        // Keep this Unix pathname literal; lstat below checks the actual endpoints.
        let parent = components.dropLast().joined(separator: "/")
        var directory = stat()
        var socket = stat()
        guard lstat(parent, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == getuid(), directory.st_mode & 0o7777 == 0o700,
              lstat(path, &socket) == 0, socket.st_mode & S_IFMT == S_IFSOCK,
              socket.st_uid == getuid(), socket.st_mode & 0o7777 == 0o600 else {
            throw PoCError.invalid("gateway requires a current-user 0700 directory and 0600 Unix socket without symlinks")
        }
    }
}

private struct BridgeResult: Sendable {
    let guestToGatewayBytes: UInt64
    let gatewayToGuestBytes: UInt64
    let reason: String
    let errorNumber: Int32?
}

// Only owned duplicate/socket descriptors cross queues. Virtualization objects stay on MainActor.
private final class OpaqueBytePump: @unchecked Sendable {
    private let lock = NSLock()
    private let guestFD: Int32
    private let gatewayFD: Int32
    private let socketPath: String
    private let completion: @Sendable (BridgeResult) -> Void
    private var stopped = false
    private var closed = false
    private var reason = "eof"
    private var errorNumber: Int32?
    private var guestBytes: UInt64 = 0
    private var gatewayBytes: UInt64 = 0

    init(guestFD: Int32, gatewayFD: Int32, socketPath: String,
         completion: @escaping @Sendable (BridgeResult) -> Void) {
        self.guestFD = guestFD
        self.gatewayFD = gatewayFD
        self.socketPath = socketPath
        self.completion = completion
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            if isStopped { finish(); return }
            do { try VsockTransportConfiguration.validateGatewaySocket(path: socketPath) }
            catch { requestStop(reason: "private_endpoint_invalid"); finish(); return }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socketPath.utf8) + [0]
            address.sun_len = UInt8(2 + bytes.count)
            withUnsafeMutableBytes(of: &address.sun_path) { target in
                target.copyBytes(from: bytes)
            }
            let addressLength = socklen_t(address.sun_len)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(gatewayFD, $0, addressLength)
                }
            }
            if connected < 0 {
                let connectError = errno
                guard connectError == EINPROGRESS else {
                    requestStop(reason: "gateway_connect_error", error: connectError); finish(); return
                }
                guard finishConnecting() else { finish(); return }
            }
            if isStopped { requestStop(reason: "transport_shutdown"); finish(); return }
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                copy(from: guestFD, to: gatewayFD, guestToGateway: true)
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                copy(from: gatewayFD, to: guestFD, guestToGateway: false)
                group.leave()
            }
            group.notify(queue: .global(qos: .utility)) { [self] in finish() }
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func finishConnecting() -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !isStopped && ProcessInfo.processInfo.systemUptime < deadline {
            var item = pollfd(fd: gatewayFD, events: Int16(POLLOUT), revents: 0)
            let ready = Darwin.poll(&item, 1, 100)
            if ready > 0 {
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(gatewayFD, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
                    requestStop(reason: "gateway_connect_error", error: errno); return false
                }
                guard socketError == 0 else {
                    requestStop(reason: "gateway_connect_error", error: socketError); return false
                }
                return !isStopped
            }
            if ready < 0, errno != EINTR {
                requestStop(reason: "gateway_connect_error", error: errno); return false
            }
        }
        if !isStopped { requestStop(reason: "gateway_connect_timeout") }
        return false
    }

    func requestStop(reason newReason: String, error: Int32? = nil) {
        lock.withLock {
            guard !closed else { return }
            if !stopped { reason = newReason; errorNumber = error }
            stopped = true
            // Interrupt reads/writes; close occurs only after both pumps have returned.
            _ = Darwin.shutdown(guestFD, SHUT_RDWR)
            _ = Darwin.shutdown(gatewayFD, SHUT_RDWR)
        }
    }

    private func waitReady(_ descriptor: Int32, events: Int16) -> Bool {
        while !isStopped {
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = Darwin.poll(&item, 1, 1000)
            if ready > 0 { return true }
            if ready < 0, errno != EINTR {
                requestStop(reason: "poll_error", error: errno); return false
            }
        }
        return false
    }

    private func copy(from source: Int32, to destination: Int32, guestToGateway: Bool) {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !isStopped {
            let count = Darwin.read(source, &buffer, buffer.count)
            if count == 0 { requestStop(reason: "eof"); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if waitReady(source, events: Int16(POLLIN)) { continue }
                    return
                }
                requestStop(reason: "read_error", error: errno); return
            }
            var offset = 0
            while offset < count && !isStopped {
                let written = buffer.withUnsafeBytes { bytes in
                    Darwin.write(destination, bytes.baseAddress!.advanced(by: offset), count - offset)
                }
                if written > 0 {
                    offset += written
                    lock.withLock {
                        if guestToGateway { guestBytes += UInt64(written) }
                        else { gatewayBytes += UInt64(written) }
                    }
                } else if written < 0 && errno == EINTR {
                    continue
                } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    guard waitReady(destination, events: Int16(POLLOUT)) else { return }
                } else {
                    requestStop(reason: "write_error", error: written == 0 ? nil : errno); return
                }
            }
        }
    }

    private func finish() {
        let result: BridgeResult? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            _ = Darwin.close(guestFD)
            _ = Darwin.close(gatewayFD)
            return BridgeResult(guestToGatewayBytes: guestBytes, gatewayToGuestBytes: gatewayBytes,
                                reason: reason, errorNumber: errorNumber)
        }
        if let result { completion(result) }
    }
}

@MainActor
final class VsockBridgeTransport: NSObject, @preconcurrency VZVirtioSocketListenerDelegate {
    private struct ActiveBridge {
        let connection: VZVirtioSocketConnection
        let pump: OpaqueBytePump
    }
    private let configuration: VsockTransportConfiguration
    private let device: VZVirtioSocketDevice
    private let log: ([String: Any]) -> Void
    private var listener: VZVirtioSocketListener?
    private var bridges: [UUID: ActiveBridge] = [:]
    private var closing = false
    private var shutdownCallbacks: [() -> Void] = []
    private var accepted = 0
    private var rejected = 0
    private var closedCount = 0
    private var guestBytes: UInt64 = 0
    private var gatewayBytes: UInt64 = 0

    init(configuration: VsockTransportConfiguration, device: VZVirtioSocketDevice,
         log: @escaping ([String: Any]) -> Void) {
        self.configuration = configuration
        self.device = device
        self.log = log
    }

    func register() {
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        self.listener = listener
        device.setSocketListener(listener, forPort: VsockTransportConfiguration.port)
        log(["kind": "transport_registered", "fixture": true, "vsock_port": VsockTransportConfiguration.port,
             "max_connections": 4, "payload_visibility": "opaque_tls_bytes"])
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        guard !closing, bridges.count < 4, connection.destinationPort == VsockTransportConfiguration.port,
              connection.fileDescriptor >= 0 else {
            rejected += 1
            log(["kind": "transport_rejected", "reason": closing ? "shutting_down" : "connection_limit_or_port",
                 "rejected_count": rejected])
            return false
        }
        let duplicate = Darwin.dup(connection.fileDescriptor)
        guard duplicate >= 0 else {
            rejected += 1
            log(["kind": "transport_rejected", "reason": "descriptor_dup_error", "errno": errno,
                 "rejected_count": rejected])
            return false
        }
        let unixFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard unixFD >= 0 else {
            let errorNumber = errno
            _ = Darwin.close(duplicate)
            rejected += 1
            log(["kind": "transport_rejected", "reason": "unix_socket_error", "errno": errorNumber,
                 "rejected_count": rejected])
            return false
        }
        var noSigPipe: Int32 = 1
        for descriptor in [duplicate, unixFD] {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
                  setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                let errorNumber = errno
                _ = Darwin.close(duplicate)
                _ = Darwin.close(unixFD)
                rejected += 1
                log(["kind": "transport_rejected", "reason": "descriptor_setup_error", "errno": errorNumber,
                     "rejected_count": rejected])
                return false
            }
        }
        let currentFlags = fcntl(unixFD, F_GETFL)
        guard currentFlags >= 0, fcntl(unixFD, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            let errorNumber = errno
            _ = Darwin.close(duplicate)
            _ = Darwin.close(unixFD)
            rejected += 1
            log(["kind": "transport_rejected", "reason": "descriptor_setup_error", "errno": errorNumber,
                 "rejected_count": rejected])
            return false
        }
        let id = UUID()
        let pump = OpaqueBytePump(guestFD: duplicate, gatewayFD: unixFD,
                                  socketPath: configuration.gatewaySocketPath) { [weak self] result in
            Task { @MainActor in self?.didClose(id, result: result) }
        }
        bridges[id] = ActiveBridge(connection: connection, pump: pump)
        accepted += 1
        log(["kind": "transport_accepted", "accepted_count": accepted, "active_connections": bridges.count])
        pump.start()
        return true
    }

    private func didClose(_ id: UUID, result: BridgeResult) {
        guard let bridge = bridges.removeValue(forKey: id) else { return }
        if bridge.connection.fileDescriptor >= 0 { bridge.connection.close() }
        closedCount += 1
        guestBytes += result.guestToGatewayBytes
        gatewayBytes += result.gatewayToGuestBytes
        var event: [String: Any] = ["kind": "transport_closed", "closed_count": closedCount,
                                  "active_connections": bridges.count, "reason": result.reason,
                                  "guest_to_gateway_bytes": result.guestToGatewayBytes,
                                  "gateway_to_guest_bytes": result.gatewayToGuestBytes]
        if let error = result.errorNumber { event["errno"] = error }
        log(event)
        completeShutdownIfReady()
    }

    func shutdown(reason: String, completion: @escaping () -> Void) {
        shutdownCallbacks.append(completion)
        if !closing {
            closing = true
            device.removeSocketListener(forPort: VsockTransportConfiguration.port)
            listener?.delegate = nil
            listener = nil
            for bridge in bridges.values {
                bridge.pump.requestStop(reason: reason)
                bridge.connection.close()
            }
        }
        completeShutdownIfReady()
    }

    private func completeShutdownIfReady() {
        guard closing, bridges.isEmpty, !shutdownCallbacks.isEmpty else { return }
        log(["kind": "transport_shutdown", "accepted_count": accepted, "rejected_count": rejected,
             "closed_count": closedCount, "active_connections": 0,
             "guest_to_gateway_bytes": guestBytes, "gateway_to_guest_bytes": gatewayBytes])
        let callbacks = shutdownCallbacks
        shutdownCallbacks.removeAll()
        for callback in callbacks { callback() }
    }
}
