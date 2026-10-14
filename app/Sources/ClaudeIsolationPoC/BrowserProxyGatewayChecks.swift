import Darwin
import Foundation

/// Local transport checks use only socket pairs and a bound loopback proxy.
/// The proxy fixture never resolves or connects to the CONNECT authority.
func browserProxyGatewayChecks() -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    let rejectedProxyURLs = [
        "https://127.0.0.1:17897", "http://proxy.example.com:17897",
        "http://user:password@127.0.0.1:17897", "http://127.0.0.1:17897/private",
        "http://127.0.0.1:17897?route=other", "http://127.0.0.1:17897#fragment"
    ]
    var rejectedProxyURLCount = 0
    for url in rejectedProxyURLs {
        do {
            let gateway = try BrowserProxyGateway(proxyURL: url)
            gateway.stop()
        } catch BrowserProxyGateway.ConfigurationError.invalidProxyURL {
            rejectedProxyURLCount += 1
        } catch {
            checks.append(("browser_proxy_invalid_proxy_url_unexpected_error", false))
        }
    }
    checks.append(("browser_proxy_invalid_proxy_urls_rejected", rejectedProxyURLCount == rejectedProxyURLs.count))

    browserProxyRunCheck("connect", checks: &checks) { fixture, checks in
        let client = try fixture.makeClient()
        let earlyBytes = Data([0x16, 0x03, 0x01, 0x00, 0xff, 0x7f, 0x00])
        let guestHeader = "CONNECT Api.Example.Com:443 HTTP/1.1\r\nHost: API.EXAMPLE.COM:443\r\nAuthorization: fixture-only\r\nProxy-Authorization: fixture-only\r\nCookie: fixture-only\r\nX-Guest: fixture-only\r\nContent-Length: 0\r\n\r\n"
        try client.write(Data(guestHeader.utf8) + earlyBytes)
        let proxy = try fixture.acceptProxy()
        let reconstructed = try proxy.readHeader()
        checks.append(("browser_proxy_connect_authority_rebuilt_without_guest_headers",
            reconstructed == Data("CONNECT api.example.com:443 HTTP/1.1\r\nHost: api.example.com:443\r\n\r\n".utf8)))
        let initialReply = Data([0x16, 0x03, 0x03, 0x00, 0x00, 0xff])
        try proxy.write(Data("HTTP/1.1 200 Connection established\r\nX-Upstream-Secret: fixture-only\r\n\r\n".utf8) + initialReply)
        let downstreamHeader = try client.readHeader()
        checks.append(("browser_proxy_upstream_success_header_is_sanitized",
            String(decoding: downstreamHeader, as: UTF8.self).hasPrefix("HTTP/1.1 200 ") &&
            !String(decoding: downstreamHeader, as: UTF8.self).contains("X-Upstream-Secret")))
        checks.append(("browser_proxy_connect_coalesced_opaque_bytes_preserved",
            try proxy.readExactly(earlyBytes.count) == earlyBytes && client.readExactly(initialReply.count) == initialReply))

        let payload = Data((0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 37) })
        checks.append(("browser_proxy_large_client_to_proxy_bytes_and_backpressure",
            try browserProxyTransfer(payload, from: client, to: proxy) == payload))
        checks.append(("browser_proxy_large_proxy_to_client_bytes_and_backpressure",
            try browserProxyTransfer(payload, from: proxy, to: client) == payload))
        fixture.gateway.stop()
        let clientClosed = try client.readUntilEOF().closed
        let proxyClosed = try proxy.readUntilEOF().closed
        checks.append(("browser_proxy_stop_closes_active_tunnel_and_drains",
            clientClosed && proxyClosed && fixture.waitForSettlement() && fixture.gateway.activeCount == 0))
        checks.append(("browser_proxy_stop_releases_owned_guest_descriptor", fixture.ownedDescriptorsAreClosed))
        checks.append(("browser_proxy_success_active_count_events_are_balanced",
            fixture.events.activeCounts.contains(1) && fixture.events.activeCounts.last == 0 && fixture.events.failures.isEmpty))
    }

    for clientFinishesFirst in [true, false] {
        let name = clientFinishesFirst ? "client_half_close" : "upstream_half_close"
        browserProxyRunCheck(name, checks: &checks) { fixture, checks in
            let (client, proxy) = try fixture.connectedTunnel()
            let first = clientFinishesFirst ? client : proxy
            let second = clientFinishesFirst ? proxy : client
            let firstPayload = Data([0x00, 0xff, 0x16, 0x80, 0x03])
            let finalPayload = Data([0x17, 0x03, 0x03, 0x00, 0xff, 0x00, 0x80])
            try first.write(firstPayload)
            try first.finishWriting()
            let firstDelivery = try second.readUntilEOF()
            try second.write(finalPayload)
            try second.finishWriting()
            let finalDelivery = try first.readUntilEOF()
            checks.append(("browser_proxy_\(name)_preserves_reverse_direction",
                firstDelivery.closed && firstDelivery.data == firstPayload &&
                finalDelivery.closed && finalDelivery.data == finalPayload && fixture.waitForSettlement()))
        }
    }

    let upstreamFailures: [(String, Data?, BrowserProxyGateway.Failure)] = [
        ("upstream_rejection", Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: fixture-only\r\n\r\n".utf8), .upstreamRejected),
        ("upstream_header_injection", Data("HTTP/1.1 200 OK\r\nX-Fixture: value\rInjected: forbidden\r\n\r\n".utf8), .upstreamInvalidResponse),
        ("upstream_bad_status", Data("HTTP/1.1 2000 Confused\r\n\r\n".utf8), .upstreamInvalidResponse),
        ("upstream_disconnect", nil, .upstreamUnavailable)
    ]
    for (name, response, failure) in upstreamFailures {
        browserProxyRunCheck(name, checks: &checks) { fixture, checks in
            let client = try fixture.makeClient()
            try client.write(browserProxyValidConnect)
            let proxy = try fixture.acceptProxy()
            _ = try proxy.readHeader()
            if let response { try proxy.write(response) }
            else { proxy.closeOwned() }
            let reply = try client.readUntilEOF()
            let text = String(decoding: reply.data, as: UTF8.self)
            checks.append(("browser_proxy_\(name)_fails_closed",
                reply.closed && !text.hasPrefix("HTTP/1.1 200 ") &&
                !text.contains("Proxy-Authenticate") && fixture.waitForSettlement() && fixture.events.failures.contains(failure)))
        }
    }

    let limitedHeaders = BrowserProxyGateway.Limits(maximumHeaderBytes: 256, headerTimeout: 0.2, connectTimeout: 0.2)
    browserProxyRunCheck("upstream_header_overflow", limits: limitedHeaders, checks: &checks) { fixture, checks in
        let client = try fixture.makeClient()
        try client.write(browserProxyValidConnect)
        let proxy = try fixture.acceptProxy()
        _ = try proxy.readHeader()
        try proxy.write(Data(("HTTP/1.1 200 OK\r\nX-Fixture: " + String(repeating: "x", count: 1024) + "\r\n\r\n").utf8))
        let reply = try client.readUntilEOF()
        checks.append(("browser_proxy_upstream_header_overflow_fails_closed",
            reply.closed && !String(decoding: reply.data, as: UTF8.self).hasPrefix("HTTP/1.1 200 ") &&
            fixture.waitForSettlement() && fixture.events.failures.contains(.upstreamInvalidResponse)))
    }
    browserProxyRunCheck("upstream_header_timeout", limits: limitedHeaders, checks: &checks) { fixture, checks in
        let client = try fixture.makeClient()
        try client.write(browserProxyValidConnect)
        let proxy = try fixture.acceptProxy()
        _ = try proxy.readHeader()
        let reply = try client.readUntilEOF()
        checks.append(("browser_proxy_upstream_header_timeout_is_bounded",
            reply.closed && !String(decoding: reply.data, as: UTF8.self).hasPrefix("HTTP/1.1 200 ") &&
            fixture.waitForSettlement() && fixture.events.failures.contains(.upstreamUnavailable)))
    }
    browserProxyRunCheck("stop_during_upstream_header", checks: &checks) { fixture, checks in
        let client = try fixture.makeClient()
        try client.write(browserProxyValidConnect)
        let proxy = try fixture.acceptProxy()
        _ = try proxy.readHeader()
        fixture.gateway.stop()
        let clientClosed = try client.readUntilEOF().closed
        let proxyClosed = try proxy.readUntilEOF().closed
        checks.append(("browser_proxy_stop_interrupts_upstream_header_wait",
            clientClosed && proxyClosed && fixture.waitForSettlement() && fixture.ownedDescriptorsAreClosed))
    }

    let invalidRequests: [(String, String)] = [
        ("ipv4", "CONNECT 8.8.8.8:443 HTTP/1.1\r\n\r\n"),
        ("ipv6", "CONNECT [2606:4700:4700::1111]:443 HTTP/1.1\r\n\r\n"),
        ("loopback", "CONNECT 127.0.0.1:443 HTTP/1.1\r\n\r\n"),
        ("localhost", "CONNECT localhost:443 HTTP/1.1\r\n\r\n"),
        ("private_local_suffix", "CONNECT router.local:443 HTTP/1.1\r\n\r\n"),
        ("private_localhost_suffix", "CONNECT service.localhost:443 HTTP/1.1\r\n\r\n"),
        ("private_internal_suffix", "CONNECT service.internal:443 HTTP/1.1\r\n\r\n"),
        ("private_onion_suffix", "CONNECT service.onion:443 HTTP/1.1\r\n\r\n"),
        ("trailing_dot", "CONNECT api.example.com.:443 HTTP/1.1\r\n\r\n"),
        ("numeric_tld", "CONNECT api.example.123:443 HTTP/1.1\r\n\r\n"),
        ("empty_label", "CONNECT api..example.com:443 HTTP/1.1\r\n\r\n"),
        ("userinfo", "CONNECT user@api.example.com:443 HTTP/1.1\r\n\r\n"),
        ("url", "CONNECT https://api.example.com:443 HTTP/1.1\r\n\r\n"),
        ("path", "CONNECT api.example.com:443/path HTTP/1.1\r\n\r\n"),
        ("wrong_port", "CONNECT api.example.com:80 HTTP/1.1\r\n\r\n"),
        ("leading_zero_port", "CONNECT api.example.com:0443 HTTP/1.1\r\n\r\n"),
        ("signed_port", "CONNECT api.example.com:+443 HTTP/1.1\r\n\r\n"),
        ("duplicate_port", "CONNECT api.example.com:443:443 HTTP/1.1\r\n\r\n"),
        ("non_connect", "GET https://api.example.com/ HTTP/1.1\r\n\r\n"),
        ("request_line_injection", "CONNECT api.example.com:443 HTTP/1.1\rInjected: forbidden\r\n\r\n"),
        ("header_injection", "CONNECT api.example.com:443 HTTP/1.1\r\nX-Fixture: value\rInjected: forbidden\r\n\r\n"),
        ("header_nul", "CONNECT api.example.com:443 HTTP/1.1\r\nX-Fixture: value\u{0}forbidden\r\n\r\n"),
        ("folded_header", "CONNECT api.example.com:443 HTTP/1.1\r\nX-Fixture: value\r\n injected\r\n\r\n"),
        ("mismatched_host", "CONNECT api.example.com:443 HTTP/1.1\r\nHost: other.example.com:443\r\n\r\n"),
        ("positive_content_length", "CONNECT api.example.com:443 HTTP/1.1\r\nContent-Length: 1\r\n\r\n"),
        ("transfer_encoding", "CONNECT api.example.com:443 HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
    ]
    for (name, request) in invalidRequests {
        browserProxyRunCheck("invalid_\(name)", limits: limitedHeaders, checks: &checks) { fixture, checks in
            let client = try fixture.makeClient()
            try client.write(Data(request.utf8))
            let reply = try client.readUntilEOF()
            checks.append(("browser_proxy_invalid_\(name)_rejected_before_upstream",
                reply.closed && !String(decoding: reply.data, as: UTF8.self).hasPrefix("HTTP/1.1 200 ") &&
                fixture.waitForSettlement() && !fixture.listener.hasPendingConnection && !fixture.events.failures.isEmpty))
        }
    }
    browserProxyRunCheck("guest_header_overflow", limits: limitedHeaders, checks: &checks) { fixture, checks in
        let client = try fixture.makeClient()
        try client.write(Data(("CONNECT api.example.com:443 HTTP/1.1\r\nX-Fixture: " + String(repeating: "x", count: 1024)).utf8))
        let reply = try client.readUntilEOF()
        checks.append(("browser_proxy_guest_header_overflow_rejected_before_upstream",
            reply.closed && fixture.waitForSettlement() && !fixture.listener.hasPendingConnection && fixture.events.failures.contains(.headerTooLarge)))
    }
    browserProxyRunCheck("guest_header_timeout", limits: limitedHeaders, checks: &checks) { fixture, checks in
        let client = try fixture.makeClient()
        try client.write(Data("CONNECT api.example.com:443 HTTP/1.1\r\n".utf8))
        let reply = try client.readUntilEOF()
        checks.append(("browser_proxy_guest_header_timeout_is_bounded",
            reply.closed && fixture.waitForSettlement() && !fixture.listener.hasPendingConnection && fixture.events.failures.contains(.headerTimeout)))
    }
    browserProxyRunCheck("guest_header_disconnect", limits: limitedHeaders, checks: &checks) { fixture, checks in
        let client = try fixture.makeClient()
        try client.write(Data("CONNECT api.example.com:443".utf8))
        try client.finishWriting()
        let reply = try client.readUntilEOF()
        checks.append(("browser_proxy_guest_header_disconnect_drains",
            reply.closed && fixture.waitForSettlement() && !fixture.listener.hasPendingConnection && fixture.events.failures.contains(.invalidRequest)))
    }

    browserProxyRunCheck("proxy_connect_refused", limits: limitedHeaders, listenerIsListening: false, checks: &checks) { fixture, checks in
        let client = try fixture.makeClient()
        try client.write(browserProxyValidConnect)
        let reply = try client.readUntilEOF()
        checks.append(("browser_proxy_real_loopback_connect_refusal_is_explicit",
            reply.closed && fixture.waitForSettlement() && fixture.events.failures.contains(.upstreamUnavailable)))
    }
    let oneConnection = BrowserProxyGateway.Limits(maximumConnections: 1, headerTimeout: 2, connectTimeout: 0.2)
    browserProxyRunCheck("connection_limit", limits: oneConnection, checks: &checks) { fixture, checks in
        let first = try fixture.makeClient()
        let rejected = try BrowserProxyCheckSocket.pair()
        let accepted = fixture.gateway.acceptOwnedSocketForTesting(rejected.peer)
        let callerStillOwnsRejected = fcntl(rejected.peer, F_GETFD) >= 0
        if !accepted { Darwin.close(rejected.peer) }
        else { fixture.recordOwnedDescriptor(rejected.peer) }
        checks.append(("browser_proxy_connection_limit_rejects_without_taking_ownership",
            !accepted && callerStillOwnsRejected && fixture.gateway.activeCount == 1))
        rejected.client.closeOwned()
        fixture.gateway.stop()
        let closed = try first.readUntilEOF().closed
        checks.append(("browser_proxy_stop_interrupts_guest_header_wait_and_drains",
            closed && fixture.waitForSettlement() && fixture.gateway.activeCount == 0 && fixture.ownedDescriptorsAreClosed))
        let afterStop = try BrowserProxyCheckSocket.pair()
        let acceptedAfterStop = fixture.gateway.acceptOwnedSocketForTesting(afterStop.peer)
        let callerStillOwnsAfterStop = fcntl(afterStop.peer, F_GETFD) >= 0
        if !acceptedAfterStop { Darwin.close(afterStop.peer) }
        else { fixture.recordOwnedDescriptor(afterStop.peer) }
        afterStop.client.closeOwned()
        checks.append(("browser_proxy_stopped_gateway_rejects_new_sockets",
            !acceptedAfterStop && callerStillOwnsAfterStop && fixture.gateway.isSettled))
    }
    return checks
}

private let browserProxyValidConnect = Data("CONNECT api.example.com:443 HTTP/1.1\r\n\r\n".utf8)

private func browserProxyRunCheck(_ name: String, limits: BrowserProxyGateway.Limits = .init(),
                                 listenerIsListening: Bool = true, checks: inout [(String, Bool)],
                                 body: (BrowserProxyCheckFixture, inout [(String, Bool)]) throws -> Void) {
    do {
        let fixture = try BrowserProxyCheckFixture(limits: limits, listenerIsListening: listenerIsListening)
        defer {
            fixture.gateway.stop()
            checks.append(("browser_proxy_\(name)_fixture_settled", fixture.waitForSettlement()))
        }
        try body(fixture, &checks)
    } catch {
        checks.append(("browser_proxy_\(name)_fixture_\(error)", false))
    }
}

private enum BrowserProxyCheckError: Error, CustomStringConvertible {
    case system(String, Int32)
    case deadline(String)
    case disconnected(String)
    case rejectedSocket
    case excessiveData

    var description: String {
        switch self {
        case .system(let operation, let code): return "\(operation)_errno_\(code)"
        case .deadline(let operation): return "\(operation)_deadline"
        case .disconnected(let operation): return "\(operation)_disconnected"
        case .rejectedSocket: return "socket_rejected"
        case .excessiveData: return "excessive_data"
        }
    }
}

private final class BrowserProxyCheckEvents {
    private let lock = NSLock()
    private var counts: [Int] = []
    private var failureValues: [BrowserProxyGateway.Failure] = []

    func record(_ event: BrowserProxyGateway.Event) {
        lock.lock()
        counts.append(event.activeCount)
        if let failure = event.failure { failureValues.append(failure) }
        lock.unlock()
    }

    var activeCounts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    var failures: [BrowserProxyGateway.Failure] {
        lock.lock()
        defer { lock.unlock() }
        return failureValues
    }
}

private final class BrowserProxyCheckFixture {
    let listener: BrowserProxyCheckListener
    let gateway: BrowserProxyGateway
    let events: BrowserProxyCheckEvents
    private var ownedDescriptors: [Int32] = []

    init(limits: BrowserProxyGateway.Limits, listenerIsListening: Bool) throws {
        listener = try BrowserProxyCheckListener(listening: listenerIsListening)
        let events = BrowserProxyCheckEvents()
        self.events = events
        gateway = try BrowserProxyGateway(proxyURL: listener.url, limits: limits, onEvent: { events.record($0) })
    }

    func makeClient() throws -> BrowserProxyCheckSocket {
        let pair = try BrowserProxyCheckSocket.pair()
        guard gateway.acceptOwnedSocketForTesting(pair.peer) else {
            Darwin.close(pair.peer)
            throw BrowserProxyCheckError.rejectedSocket
        }
        recordOwnedDescriptor(pair.peer)
        return pair.client
    }

    func recordOwnedDescriptor(_ descriptor: Int32) { ownedDescriptors.append(descriptor) }

    var ownedDescriptorsAreClosed: Bool {
        ownedDescriptors.allSatisfy { fcntl($0, F_GETFD) == -1 && errno == EBADF }
    }

    func acceptProxy() throws -> BrowserProxyCheckSocket { try listener.acceptConnection() }

    func connectedTunnel() throws -> (BrowserProxyCheckSocket, BrowserProxyCheckSocket) {
        let client = try makeClient()
        try client.write(browserProxyValidConnect)
        let proxy = try acceptProxy()
        _ = try proxy.readHeader()
        try proxy.write(Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8))
        let reply = try client.readHeader()
        guard String(decoding: reply, as: UTF8.self).hasPrefix("HTTP/1.1 200 ") else {
            throw BrowserProxyCheckError.disconnected("connect_response")
        }
        return (client, proxy)
    }

    func waitForSettlement(timeout: TimeInterval = 2) -> Bool {
        let deadline = browserProxyCheckNow() + timeout
        while browserProxyCheckNow() < deadline {
            // Event delivery runs on a serial queue after the worker removes
            // its owned descriptors. Wait for that observable completion too.
            if gateway.isSettled && events.activeCounts.last == 0 { return true }
            usleep(1_000)
        }
        return gateway.isSettled && events.activeCounts.last == 0
    }
}

private final class BrowserProxyCheckListener {
    let descriptor: Int32
    let url: String

    init(listening: Bool) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BrowserProxyCheckError.system("listener_socket", errno) }
        var keepDescriptor = false
        defer { if !keepDescriptor { Darwin.close(descriptor) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw BrowserProxyCheckError.system("bind", errno) }
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &addressLength) }
        }
        guard named == 0 else { throw BrowserProxyCheckError.system("getsockname", errno) }
        if listening && Darwin.listen(descriptor, 8) != 0 { throw BrowserProxyCheckError.system("listen", errno) }
        try browserProxyCheckConfigure(descriptor)
        self.descriptor = descriptor
        url = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        keepDescriptor = true
    }

    deinit { Darwin.close(descriptor) }

    var hasPendingConnection: Bool {
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&event, 1, 0) > 0 && (event.revents & Int16(POLLIN)) != 0
    }

    func acceptConnection(timeout: TimeInterval = 2) throws -> BrowserProxyCheckSocket {
        let deadline = browserProxyCheckNow() + timeout
        while true {
            let accepted = Darwin.accept(descriptor, nil, nil)
            if accepted >= 0 {
                do { return try BrowserProxyCheckSocket(owning: accepted) }
                catch { Darwin.close(accepted); throw error }
            }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else {
                throw BrowserProxyCheckError.system("accept", errno)
            }
            try browserProxyCheckPoll(descriptor, events: Int16(POLLIN), deadline: deadline, operation: "accept")
        }
    }
}

private final class BrowserProxyCheckSocket {
    private(set) var descriptor: Int32
    private var pending = Data()

    init(owning descriptor: Int32) throws {
        self.descriptor = descriptor
        try browserProxyCheckConfigure(descriptor)
    }

    deinit { closeOwned() }

    func closeOwned() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }

    static func pair() throws -> (client: BrowserProxyCheckSocket, peer: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw BrowserProxyCheckError.system("socketpair", errno)
        }
        do {
            try browserProxyCheckConfigure(descriptors[1])
            let client = try BrowserProxyCheckSocket(owning: descriptors[0])
            return (client, descriptors[1])
        } catch {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
            throw error
        }
    }

    func finishWriting() throws {
        guard shutdown(descriptor, SHUT_WR) == 0 else { throw BrowserProxyCheckError.system("shutdown", errno) }
    }

    func write(_ data: Data, timeout: TimeInterval = 2) throws {
        let deadline = browserProxyCheckNow() + timeout
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { buffer in
                Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if written > 0 { offset += written; continue }
            if written < 0 && errno == EINTR { continue }
            guard written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else {
                throw BrowserProxyCheckError.system("send", errno)
            }
            try browserProxyCheckPoll(descriptor, events: Int16(POLLOUT), deadline: deadline, operation: "write")
        }
    }

    func readHeader(timeout: TimeInterval = 2) throws -> Data {
        let deadline = browserProxyCheckNow() + timeout
        let separator = Data([13, 10, 13, 10])
        while true {
            if let range = pending.range(of: separator) {
                let end = range.upperBound
                let header = pending.prefix(end)
                pending.removeFirst(end)
                return Data(header)
            }
            guard pending.count < 32_768 else { throw BrowserProxyCheckError.excessiveData }
            guard let bytes = try receive(deadline: deadline) else { throw BrowserProxyCheckError.disconnected("header") }
            pending.append(bytes)
        }
    }

    func readExactly(_ count: Int, timeout: TimeInterval = 2) throws -> Data {
        let deadline = browserProxyCheckNow() + timeout
        while pending.count < count {
            guard let bytes = try receive(deadline: deadline) else { throw BrowserProxyCheckError.disconnected("read_exactly") }
            pending.append(bytes)
        }
        let value = Data(pending.prefix(count))
        pending.removeFirst(count)
        return value
    }

    func readUntilEOF(timeout: TimeInterval = 2) throws -> (data: Data, closed: Bool) {
        let deadline = browserProxyCheckNow() + timeout
        var value = pending
        pending.removeAll()
        while let bytes = try receive(deadline: deadline) {
            value.append(bytes)
            guard value.count <= 1_048_576 else { throw BrowserProxyCheckError.excessiveData }
        }
        return (value, true)
    }

    private func receive(deadline: TimeInterval) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if count > 0 { return Data(bytes.prefix(count)) }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            // A reset also closes this fixture's stream. The gateway may close
            // without reading the oversized or invalid request in its entirety.
            if errno == ECONNRESET { return nil }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { throw BrowserProxyCheckError.system("recv", errno) }
            try browserProxyCheckPoll(descriptor, events: Int16(POLLIN), deadline: deadline, operation: "read")
        }
    }
}

/// Pump the fixture's sender and receiver together so a bounded gateway buffer
/// cannot deadlock the check while a large sender is blocked on backpressure.
private func browserProxyTransfer(_ data: Data, from source: BrowserProxyCheckSocket,
                                  to destination: BrowserProxyCheckSocket) throws -> Data {
    let deadline = browserProxyCheckNow() + 5
    var sent = 0
    var received = Data()
    var bytes = [UInt8](repeating: 0, count: 16_384)
    while sent < data.count || received.count < data.count {
        guard browserProxyCheckNow() < deadline else { throw BrowserProxyCheckError.deadline("transfer") }
        var events = [
            pollfd(fd: source.descriptor, events: sent < data.count ? Int16(POLLOUT) : 0, revents: 0),
            pollfd(fd: destination.descriptor, events: received.count < data.count ? Int16(POLLIN) : 0, revents: 0)
        ]
        let ready = poll(&events, nfds_t(events.count), 50)
        if ready < 0 {
            if errno == EINTR { continue }
            throw BrowserProxyCheckError.system("transfer_poll", errno)
        }
        if sent < data.count && (events[0].revents & Int16(POLLOUT)) != 0 {
            let written = data.withUnsafeBytes { buffer in
                Darwin.send(source.descriptor, buffer.baseAddress!.advanced(by: sent), min(16_384, data.count - sent), 0)
            }
            if written > 0 { sent += written }
            else if written < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw BrowserProxyCheckError.system("transfer_send", errno)
            }
        }
        if received.count < data.count && (events[1].revents & Int16(POLLIN | POLLHUP | POLLERR)) != 0 {
            let count = Darwin.recv(destination.descriptor, &bytes, min(bytes.count, data.count - received.count), 0)
            if count > 0 { received.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 { throw BrowserProxyCheckError.disconnected("transfer") }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw BrowserProxyCheckError.system("transfer_recv", errno)
            }
        }
        if (events[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 {
            throw BrowserProxyCheckError.disconnected("transfer_sender")
        }
    }
    return received
}

private func browserProxyCheckConfigure(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw BrowserProxyCheckError.system("nonblocking", errno)
    }
    var noSigPipe: Int32 = 1
    guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw BrowserProxyCheckError.system("nosigpipe", errno)
    }
}

private func browserProxyCheckNow() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

private func browserProxyCheckPoll(_ descriptor: Int32, events: Int16, deadline: TimeInterval,
                                   operation: String) throws {
    while true {
        let remaining = deadline - browserProxyCheckNow()
        guard remaining > 0 else { throw BrowserProxyCheckError.deadline(operation) }
        var event = pollfd(fd: descriptor, events: events, revents: 0)
        let result = poll(&event, 1, Int32(min(remaining * 1000, 100).rounded(.up)))
        if result > 0 {
            if (event.revents & Int16(POLLNVAL)) != 0 { throw BrowserProxyCheckError.system(operation, EBADF) }
            return
        }
        if result < 0 && errno != EINTR { throw BrowserProxyCheckError.system(operation, errno) }
    }
}
