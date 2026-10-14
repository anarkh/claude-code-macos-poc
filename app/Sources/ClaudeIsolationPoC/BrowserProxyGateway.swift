import Darwin
import Foundation
import Virtualization

/// A bounded, opaque HTTPS tunnel from the browser VM to its dedicated loopback
/// proxy. It never resolves a website on the host or terminates browser TLS.
final class BrowserProxyGateway: @unchecked Sendable {
    static let port: UInt32 = 40125

    struct Limits {
        var maximumConnections: Int
        var maximumHeaderBytes: Int
        var headerTimeout: TimeInterval
        var connectTimeout: TimeInterval
        var bufferBytes: Int

        init(maximumConnections: Int = 64, maximumHeaderBytes: Int = 16_384,
             headerTimeout: TimeInterval = 10, connectTimeout: TimeInterval = 10,
             bufferBytes: Int = 32_768) {
            self.maximumConnections = maximumConnections
            self.maximumHeaderBytes = maximumHeaderBytes
            self.headerTimeout = headerTimeout
            self.connectTimeout = connectTimeout
            self.bufferBytes = bufferBytes
        }
    }

    enum Failure: String, Error, Sendable {
        case invalidRequest = "BROWSER_CONNECT_INVALID"
        case targetDenied = "BROWSER_TARGET_DENIED"
        case headerTooLarge = "BROWSER_HEADER_TOO_LARGE"
        case headerTimeout = "BROWSER_HEADER_TIMEOUT"
        case upstreamUnavailable = "BROWSER_PROXY_UNAVAILABLE"
        case upstreamRejected = "BROWSER_CONNECT_REJECTED"
        case upstreamInvalidResponse = "BROWSER_PROXY_RESPONSE_INVALID"
        case ioFailure = "BROWSER_TUNNEL_IO_FAILED"
        case connectionLimit = "BROWSER_CONNECTION_LIMIT"
        case stopped = "BROWSER_GATEWAY_STOPPED"
    }

    enum ConfigurationError: Error {
        case invalidProxyURL
        case invalidLimits
    }

    /// Deliberately contains no target, URL, header, body, or byte sample.
    struct Event: Sendable {
        let activeCount: Int
        let failure: Failure?
    }

    private let proxyPort: UInt16
    private let limits: Limits
    private let onEvent: (Event) -> Void
    private let events = DispatchQueue(label: "claude.browser.gateway.events")
    private let workers = DispatchQueue(label: "claude.browser.gateway.connections", attributes: .concurrent)
    private let lock = NSLock()
    private var admitting = true
    private var sessions: [UUID: BrowserProxySession] = [:]
    private var pendingEvent: Event?
    private var eventDeliveryScheduled = false

    init(proxyURL: String = "http://127.0.0.1:17897", limits: Limits = .init(),
         onEvent: @escaping (Event) -> Void = { _ in }) throws {
        let prefix = "http://127.0.0.1:"
        guard proxyURL.hasPrefix(prefix) else { throw ConfigurationError.invalidProxyURL }
        let text = String(proxyURL.dropFirst(prefix.count))
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(text), port > 0, String(port) == text else {
            throw ConfigurationError.invalidProxyURL
        }
        guard (1...64).contains(limits.maximumConnections),
              (256...16_384).contains(limits.maximumHeaderBytes),
              limits.headerTimeout.isFinite, (0.01...30).contains(limits.headerTimeout),
              limits.connectTimeout.isFinite, (0.01...30).contains(limits.connectTimeout),
              (256...65_536).contains(limits.bufferBytes) else {
            throw ConfigurationError.invalidLimits
        }
        self.proxyPort = port
        self.limits = limits
        self.onEvent = onEvent
    }

    var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.count
    }

    /// Remains false until all descriptor owners have closed, including the VZ
    /// connection owner on the main queue. Poll this asynchronously during stop.
    var isSettled: Bool { activeCount == 0 }

    /// Invoke from the VM's listener delegate on its main queue. A false return
    /// leaves the VZ connection with Virtualization's rejecting listener owner.
    func accept(_ connection: VZVirtioSocketConnection) -> Bool {
        guard connection.destinationPort == Self.port, connection.fileDescriptor >= 0 else { return false }
        let descriptor = Darwin.dup(connection.fileDescriptor)
        guard descriptor >= 0 else { publish(.ioFailure); return false }
        let accepted = acceptOwned(descriptor) { completion in
            // VZ owns its original fd; the I/O worker only closes its duplicate.
            DispatchQueue.main.async {
                connection.close()
                completion()
            }
        }
        if !accepted { _ = Darwin.close(descriptor) }
        return accepted
    }

    /// Local fixture seam: ownership transfers only if true. No website sockets
    /// or DNS are created by this API; tests supply an AF_UNIX socketpair fd.
    func acceptOwnedSocketForTesting(_ descriptor: Int32) -> Bool {
        acceptOwned(descriptor) { completion in completion() }
    }

    func closeAdmission() {
        lock.lock(); defer { lock.unlock() }
        admitting = false
    }

    /// Cancellation only shuts down registered fds under their owner lock. The
    /// worker closes them once it has stopped using them, preventing fd reuse
    /// from turning a delayed stop into shutdown of an unrelated socket.
    func stop() {
        lock.lock(); defer { lock.unlock() }
        admitting = false
        for session in sessions.values { session.requestStop() }
    }

    private func acceptOwned(_ descriptor: Int32,
                             releaseExternalOwner: @escaping (@escaping () -> Void) -> Void) -> Bool {
        guard descriptor >= 0, Self.configureSocket(descriptor) else { publish(.ioFailure); return false }
        let session = BrowserProxySession(guest: descriptor)
        lock.lock()
        guard admitting else { lock.unlock(); return false }
        guard sessions.count < limits.maximumConnections else {
            publishLocked(.connectionLimit)
            lock.unlock()
            return false
        }
        sessions[session.id] = session
        publishLocked(nil)
        lock.unlock()
        workers.async { [self, session] in
            let failure = run(session)
            session.closeOwnedDescriptors()
            releaseExternalOwner { [self, session] in
                lock.lock()
                sessions.removeValue(forKey: session.id)
                publishLocked(failure == .stopped ? nil : failure)
                lock.unlock()
            }
        }
        return true
    }

    private func publish(_ failure: Failure?) {
        lock.lock(); defer { lock.unlock() }
        publishLocked(failure)
    }

    private func publishLocked(_ failure: Failure?) {
        // Admission attempts may be attacker-controlled. Keep at most one
        // pending event and one delivery job, even if the UI consumer is slow.
        pendingEvent = Event(activeCount: sessions.count, failure: failure ?? pendingEvent?.failure)
        guard !eventDeliveryScheduled else { return }
        eventDeliveryScheduled = true
        events.async { [self] in
            while true {
                lock.lock()
                guard let event = pendingEvent else {
                    eventDeliveryScheduled = false
                    lock.unlock()
                    return
                }
                pendingEvent = nil
                lock.unlock()
                onEvent(event)
            }
        }
    }

    private func run(_ session: BrowserProxySession) -> Failure? {
        var established = false
        do {
            let request = try readHeader(session.guest, session: session,
                                         deadline: session.acceptedAt + limits.headerTimeout, upstream: false)
            let authority = try Self.connectAuthority(request.header)
            let upstream = try connectProxy(session)
            let connectDeadline = Self.now + limits.connectTimeout
            try writeAll(Data("CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n\r\n".utf8),
                         to: upstream, session: session, deadline: connectDeadline, failure: .upstreamUnavailable)
            let reply = try readHeader(upstream, session: session,
                                       deadline: Self.now + limits.headerTimeout, upstream: true)
            try Self.checkProxyReply(reply.header)
            try writeAll(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), to: session.guest,
                         session: session, deadline: Self.now + limits.headerTimeout, failure: .ioFailure)
            established = true
            try relay(session, upstream: upstream, toProxy: request.remainder, toGuest: reply.remainder)
            return nil
        } catch let failure as Failure {
            if !established && failure != .stopped && !session.isStopped {
                let status: String
                switch failure {
                case .targetDenied: status = "403 Forbidden"
                case .headerTooLarge: status = "431 Request Header Fields Too Large"
                case .headerTimeout: status = "408 Request Timeout"
                case .invalidRequest: status = "400 Bad Request"
                default: status = "502 Bad Gateway"
                }
                // A fixed, credential-free failure only. An unresponsive guest
                // cannot delay cleanup indefinitely while receiving this reply.
                do {
                    try writeAll(Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                 to: session.guest, session: session, deadline: Self.now + 0.2, failure: .ioFailure)
                } catch {
                    // Cleanup continues even if the fixed rejection cannot be
                    // delivered. Preserve its category, never replace it with
                    // an error description or retry/direct network fallback.
                    return session.isStopped ? .stopped : failure
                }
            }
            return session.isStopped ? .stopped : failure
        } catch {
            // No error descriptions are exposed: OS errors can include details
            // that are unnecessary for the UI's fixed tunnel failure category.
            return session.isStopped ? .stopped : .ioFailure
        }
    }

    private struct Header {
        let header: Data
        let remainder: Data
    }

    private func readHeader(_ descriptor: Int32, session: BrowserProxySession,
                            deadline: TimeInterval, upstream: Bool) throws -> Header {
        var bytes = Data()
        let delimiter = Data([13, 10, 13, 10])
        let ioFailure: Failure = upstream ? .upstreamUnavailable : .invalidRequest
        while true {
            try session.checkRunning()
            if let marker = bytes.range(of: delimiter) {
                guard marker.upperBound <= limits.maximumHeaderBytes else {
                    throw upstream ? Failure.upstreamInvalidResponse : Failure.headerTooLarge
                }
                return Header(header: bytes.prefix(marker.upperBound), remainder: bytes.suffix(from: marker.upperBound))
            }
            guard bytes.count <= limits.maximumHeaderBytes else {
                throw upstream ? Failure.upstreamInvalidResponse : Failure.headerTooLarge
            }
            try waitFor(descriptor, events: Int16(POLLIN), session: session, deadline: deadline,
                        timeout: upstream ? .upstreamUnavailable : .headerTimeout, failure: ioFailure)
            var chunk = [UInt8](repeating: 0, count: min(4096, limits.bufferBytes))
            let count = Darwin.recv(descriptor, &chunk, chunk.count, 0)
            if count > 0 { bytes.append(contentsOf: chunk.prefix(count)) }
            else if count == 0 { throw ioFailure }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw ioFailure }
        }
    }

    /// Strict ASCII request syntax. Browser headers are checked then discarded;
    /// only the canonical validated authority is sent to the loopback proxy.
    private static func connectAuthority(_ header: Data) throws -> String {
        let lines = try headerLines(header, failure: .invalidRequest)
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[0] == "CONNECT",
              request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0" else { throw Failure.invalidRequest }
        let authority = String(request[1])
        guard authority.hasSuffix(":443") else { throw Failure.targetDenied }
        let host = String(authority.dropLast(4)).lowercased()
        guard isPublicDNSName(host) else { throw Failure.targetDenied }
        let canonical = host + ":443"
        var hostSeen = false
        for line in lines.dropFirst() {
            let field = try headerField(line, failure: .invalidRequest)
            if field.name == "host" {
                guard !hostSeen, field.value.lowercased() == canonical else { throw Failure.invalidRequest }
                hostSeen = true
            }
            if field.name == "transfer-encoding" || (field.name == "content-length" && field.value != "0") {
                throw Failure.invalidRequest
            }
        }
        return canonical
    }

    private static func isPublicDNSName(_ host: String) -> Bool {
        guard host.utf8.count <= 253, !host.isEmpty else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            let bytes = Array(label.utf8)
            func letterOrDigit(_ byte: UInt8) -> Bool { (97...122).contains(byte) || (48...57).contains(byte) }
            return (1...63).contains(bytes.count) && letterOrDigit(bytes[0]) && letterOrDigit(bytes[bytes.count - 1]) &&
                bytes.allSatisfy({ letterOrDigit($0) || $0 == 45 })
        }), labels.last!.utf8.contains(where: { (97...122).contains($0) }) else { return false }
        let privateSuffixes: Set<String> = ["localhost", "local", "localdomain", "internal", "intranet", "lan", "home",
                                            "corp", "private", "test", "invalid", "example", "onion", "i2p", "arpa"]
        return !privateSuffixes.contains(String(labels.last!))
    }

    private static func checkProxyReply(_ header: Data) throws {
        let lines = try headerLines(header, failure: .upstreamInvalidResponse)
        let status = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard status.count >= 2, status[0] == "HTTP/1.1" || status[0] == "HTTP/1.0",
              status[1].utf8.count == 3, status[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let code = Int(status[1]), (100...599).contains(code) else { throw Failure.upstreamInvalidResponse }
        for line in lines.dropFirst() { _ = try headerField(line, failure: .upstreamInvalidResponse) }
        guard (200...299).contains(code) else { throw Failure.upstreamRejected }
    }

    private static func headerLines(_ header: Data, failure: Failure) throws -> [String] {
        guard header.count >= 4, header.suffix(4) == Data([13, 10, 13, 10]) else { throw failure }
        let bytes = Array(header.dropLast(4))
        var index = 0
        while index < bytes.count {
            if bytes[index] == 13 {
                guard index + 1 < bytes.count, bytes[index + 1] == 10 else { throw failure }
                index += 2
            } else {
                guard bytes[index] == 9 || (32...126).contains(bytes[index]) else { throw failure }
                index += 1
            }
        }
        let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")
        guard !lines.isEmpty, !lines[0].isEmpty else { throw failure }
        return lines
    }

    private static func headerField(_ line: String, failure: Failure) throws -> (name: String, value: String) {
        guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw failure }
        let name = String(line[..<colon])
        let extra: Set<UInt8> = [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126]
        guard name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || extra.contains($0) }) else { throw failure }
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return (name.lowercased(), value)
    }

    private func connectProxy(_ session: BrowserProxySession) throws -> Int32 {
        try session.checkRunning()
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.upstreamUnavailable }
        guard Self.configureSocket(descriptor) else { _ = Darwin.close(descriptor); throw Failure.upstreamUnavailable }
        guard session.adoptUpstream(descriptor) else { _ = Darwin.close(descriptor); throw Failure.stopped }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = proxyPort.bigEndian
        // A literal sockaddr, never getaddrinfo, URLSession, or host DNS.
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EINTR else { throw Failure.upstreamUnavailable }
            try waitFor(descriptor, events: Int16(POLLOUT), session: session, deadline: Self.now + limits.connectTimeout,
                        timeout: .upstreamUnavailable, failure: .upstreamUnavailable)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw Failure.upstreamUnavailable }
        }
        try session.checkRunning()
        return descriptor
    }

    private func writeAll(_ bytes: Data, to descriptor: Int32, session: BrowserProxySession,
                          deadline: TimeInterval, failure: Failure) throws {
        var offset = 0
        while offset < bytes.count {
            try session.checkRunning()
            try waitFor(descriptor, events: Int16(POLLOUT), session: session, deadline: deadline,
                        timeout: failure, failure: failure)
            let count = bytes.withUnsafeBytes { pointer in
                Darwin.send(descriptor, pointer.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if count > 0 { offset += count }
            else if count == 0 { throw failure }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw failure }
        }
    }

    private func waitFor(_ descriptor: Int32, events: Int16, session: BrowserProxySession,
                         deadline: TimeInterval, timeout: Failure, failure: Failure) throws {
        while true {
            try session.checkRunning()
            let remaining = deadline - Self.now
            guard remaining > 0 else { throw timeout }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, Int32(min(1000, max(1, ceil(remaining * 1000)))))
            try session.checkRunning()
            if result > 0 {
                guard item.revents & Int16(POLLNVAL) == 0 else { throw failure }
                if item.revents & (events | Int16(POLLERR | POLLHUP)) != 0 { return }
            } else if result < 0 && errno != EINTR { throw failure }
        }
    }

    private func relay(_ session: BrowserProxySession, upstream: Int32, toProxy initialProxy: Data, toGuest initialGuest: Data) throws {
        var toProxy = initialProxy
        var toGuest = initialGuest
        var guestReads = true
        var proxyReads = true
        var guestWriteEnded = false
        var proxyWriteEnded = false
        let guest = session.guest
        while true {
            try session.checkRunning()
            if !guestReads && toProxy.isEmpty && !proxyWriteEnded {
                _ = Darwin.shutdown(upstream, SHUT_WR); proxyWriteEnded = true
            }
            if !proxyReads && toGuest.isEmpty && !guestWriteEnded {
                _ = Darwin.shutdown(guest, SHUT_WR); guestWriteEnded = true
            }
            if !guestReads && !proxyReads && toProxy.isEmpty && toGuest.isEmpty { return }
            let guestEvents = (guestReads && toProxy.count < limits.bufferBytes ? Int16(POLLIN) : 0) | (!toGuest.isEmpty ? Int16(POLLOUT) : 0)
            let proxyEvents = (proxyReads && toGuest.count < limits.bufferBytes ? Int16(POLLIN) : 0) | (!toProxy.isEmpty ? Int16(POLLOUT) : 0)
            var items = [pollfd(fd: guestEvents == 0 ? -1 : guest, events: guestEvents, revents: 0),
                         pollfd(fd: proxyEvents == 0 ? -1 : upstream, events: proxyEvents, revents: 0)]
            let result = Darwin.poll(&items, 2, 1000)
            try session.checkRunning()
            if result < 0 { if errno == EINTR { continue }; throw Failure.ioFailure }
            if result == 0 { continue }
            guard items.allSatisfy({ $0.revents & Int16(POLLNVAL) == 0 }) else { throw Failure.ioFailure }
            if guestEvents & Int16(POLLIN) != 0 && items[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                try readTunnel(guest, into: &toProxy, reading: &guestReads)
            }
            if proxyEvents & Int16(POLLIN) != 0 && items[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                try readTunnel(upstream, into: &toGuest, reading: &proxyReads)
            }
            if !toGuest.isEmpty && items[0].revents & Int16(POLLOUT | POLLHUP | POLLERR) != 0 {
                try writeTunnel(guest, bytes: &toGuest)
            }
            if !toProxy.isEmpty && items[1].revents & Int16(POLLOUT | POLLHUP | POLLERR) != 0 {
                try writeTunnel(upstream, bytes: &toProxy)
            }
        }
    }

    private func readTunnel(_ descriptor: Int32, into bytes: inout Data, reading: inout Bool) throws {
        var chunk = [UInt8](repeating: 0, count: min(16_384, limits.bufferBytes - bytes.count))
        let count = Darwin.recv(descriptor, &chunk, chunk.count, 0)
        if count > 0 { bytes.append(contentsOf: chunk.prefix(count)) }
        else if count == 0 { reading = false }
        else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw Failure.ioFailure }
    }

    private func writeTunnel(_ descriptor: Int32, bytes: inout Data) throws {
        let count = bytes.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!, bytes.count, 0) }
        if count > 0 { bytes.removeFirst(count) }
        else if count == 0 { throw Failure.ioFailure }
        else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw Failure.ioFailure }
    }

    private static func configureSocket(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        var noPipe: Int32 = 1
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 &&
            fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 &&
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// One worker owns both fds and closes them once. Stop may only shutdown while
/// holding this lock; a closed descriptor is never subsequently shut down.
private final class BrowserProxySession: @unchecked Sendable {
    let id = UUID()
    let guest: Int32
    let acceptedAt = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var upstream: Int32 = -1
    private var stopped = false
    private var closed = false

    init(guest: Int32) { self.guest = guest }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func checkRunning() throws {
        if isStopped { throw BrowserProxyGateway.Failure.stopped }
    }

    func adoptUpstream(_ descriptor: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped && !closed else { return false }
        upstream = descriptor
        return true
    }

    func requestStop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        guard !closed else { return }
        _ = Darwin.shutdown(guest, SHUT_RDWR)
        if upstream >= 0 { _ = Darwin.shutdown(upstream, SHUT_RDWR) }
    }

    func closeOwnedDescriptors() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        _ = Darwin.close(guest)
        if upstream >= 0 { _ = Darwin.close(upstream); upstream = -1 }
    }
}
