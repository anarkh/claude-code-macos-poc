import Darwin
import Foundation

/// Real local socket pairs exercise framing, EOF, cancellation, and fd ownership.
/// The fixtures never read the host clipboard, launch a guest, or record text.
func browserClipboardTransportChecks() async -> [(String, Bool)] {
    var checks: [(String, Bool)] = [
        ("browser_clipboard_fixed_port_and_utf8_byte_limit",
         BrowserClipboardTransport.port == 40127 && BrowserClipboardTransport.maximumTextBytes == 65536)
    ]

    var rejectedTimeouts = 0
    for timeout in [TimeInterval(-1), 0, 0.009, 8.001, .infinity, .nan] {
        do {
            _ = try BrowserClipboardTransport(timeout: timeout)
        } catch BrowserClipboardTransport.Failure.invalidTimeout {
            rejectedTimeouts += 1
        } catch {
            checks.append(("browser_clipboard_invalid_timeout_unexpected_error", false))
        }
    }
    checks.append(("browser_clipboard_invalid_timeouts_rejected", rejectedTimeouts == 6))
    do {
        let minimum = try BrowserClipboardTransport(timeout: 0.01)
        let maximum = try BrowserClipboardTransport(timeout: 8)
        checks.append(("browser_clipboard_timeout_boundaries_accepted", minimum.isSettled && maximum.isSettled))
    } catch { checks.append(("browser_clipboard_timeout_boundaries_accepted", false)) }

    let invalidText: [(String, String)] = [
        ("empty", ""), ("nul", "fixture\u{0}only"),
        ("ascii_overflow", String(repeating: "x", count: 65537)),
        ("utf8_byte_overflow", String(repeating: "🙂", count: 16385))
    ]
    for (name, text) in invalidText {
        var validationRejected = false
        do { try BrowserClipboardTransport.validate(text: text) }
        catch BrowserClipboardTransport.Failure.invalidText { validationRejected = true }
        catch { checks.append(("browser_clipboard_\(name)_validation_unexpected_error", false)) }
        checks.append(("browser_clipboard_\(name)_validation_rejected", validationRejected))
        await browserClipboardRunSession(name, text: text, checks: &checks) { session in
            let rejected = await browserClipboardHasFailure(session.sender, .invalidText)
            return [("browser_clipboard_\(name)_rejected_without_transfer",
                     rejected && !session.peer.hasReadableEvent && session.transport.isSettled)]
        }
    }

    let validTexts: [(String, String)] = [
        ("unicode_multiline", "本地协议夹具\n🙂\tsecond line\r\nCafe\u{301} 🎉"),
        ("ascii_boundary", String(repeating: "x", count: 65536)),
        ("utf8_boundary", String(repeating: "🙂", count: 16384))
    ]
    for (name, text) in validTexts {
        await browserClipboardRunSession(name, text: text, checks: &checks) { session in
            let request = try await Task.detached {
                let frame = try session.peer.readUntilEOF()
                try session.peer.write(Data([66, 80, 82, 49, 0]))
                try session.peer.finishWriting()
                return frame
            }.value
            let acknowledgement = try await session.sender.value
            return [("browser_clipboard_\(name)_frame_and_required_request_eof",
                     request == browserClipboardExpectedFrame(text) && acknowledgement == .completed)]
        }
    }

    var acknowledgementCodes = Set<String>()
    for status in UInt8(0)...UInt8(5) {
        let name = "ack_status_\(status)"
        await browserClipboardRunSession(name, checks: &checks) { session in
            let request = try await Task.detached {
                let frame = try session.peer.readUntilEOF()
                try session.peer.write(Data([66, 80, 82, 49, status]))
                try session.peer.finishWriting()
                return frame
            }.value
            let acknowledgement = try await session.sender.value
            acknowledgementCodes.insert(acknowledgement.code)
            return [("browser_clipboard_\(name)_accepted_as_fixed_acknowledgement",
                     request == browserClipboardExpectedFrame(session.text) &&
                     acknowledgement.rawValue == status && browserClipboardIsFixedCode(acknowledgement.code))]
        }
    }
    checks.append(("browser_clipboard_acknowledgement_codes_are_distinct", acknowledgementCodes.count == 6))

    let malformedResponses: [(String, Data)] = [
        ("wrong_prefix", Data([66, 80, 88, 49, 0])),
        ("unknown_status", Data([66, 80, 82, 49, 6])),
        ("truncated_prefix", Data([66, 80])),
        ("truncated_status", Data([66, 80, 82, 49])),
        ("empty_response", Data()),
        ("extra_byte", Data([66, 80, 82, 49, 0, 255])),
        ("extra_body", Data([66, 80, 82, 49, 0]) + Data("fixture-only-extra-body".utf8))
    ]
    for (name, response) in malformedResponses {
        await browserClipboardRunSession(name, checks: &checks) { session in
            let request = try await Task.detached {
                let frame = try session.peer.readUntilEOF()
                try session.peer.write(response)
                try session.peer.finishWriting()
                return frame
            }.value
            let invalidResponse = await browserClipboardHasFailure(session.sender, .invalidResponse)
            return [("browser_clipboard_\(name)_is_invalid_response",
                     request == browserClipboardExpectedFrame(session.text) &&
                     invalidResponse)]
        }
    }

    for (name, response) in [
        ("no_response_timeout", Data()),
        ("ack_without_eof_timeout", Data([66, 80, 82, 49, 0])),
        ("partial_response_timeout", Data([66, 80, 82]))
    ] {
        await browserClipboardRunSession(name, timeout: 0.15, checks: &checks) { session in
            let started = browserClipboardCheckNow()
            let request = try await Task.detached {
                let frame = try session.peer.readUntilEOF()
                try session.peer.write(response)
                // Keep the peer open: neither a response nor a partial/complete
                // ACK is sufficient without the required response EOF.
                return frame
            }.value
            let timedOut = await browserClipboardHasFailure(session.sender, .timedOut)
            return [("browser_clipboard_\(name)_is_bounded",
                     request == browserClipboardExpectedFrame(session.text) && timedOut &&
                     browserClipboardCheckNow() - started < 2)]
        }
    }

    for taskCancellation in [false, true] {
        let name = taskCancellation ? "task_cancel" : "explicit_cancel"
        await browserClipboardRunSession(name, checks: &checks) { session in
            let request = try await Task.detached { try session.peer.readUntilEOF() }.value
            let wasActive = !session.transport.isSettled
            if taskCancellation { session.sender.cancel() }
            else { session.transport.cancel() }
            let cancelled = await browserClipboardHasFailure(session.sender, .cancelled)
            return [("browser_clipboard_\(name)_interrupts_wait_and_retires_transfer",
                     request == browserClipboardExpectedFrame(session.text) && wasActive && cancelled && session.transport.isSettled)]
        }
    }

    await browserClipboardRunSession("concurrent_busy", checks: &checks) { session in
        let request = try await Task.detached { try session.peer.readUntilEOF() }.value
        let secondPair = try BrowserClipboardCheckSocket.pair()
        let secondSender = Task {
            try await session.transport.sendForTesting(text: "second-fixture", socketDescriptor: secondPair.client.descriptor)
        }
        let secondRejected = await browserClipboardHasFailure(secondSender, .busy)
        let secondUntouched = !secondPair.peer.hasReadableEvent && secondPair.client.isOpen
        let firstStillActive = !session.transport.isSettled
        try await Task.detached {
            try session.peer.write(Data([66, 80, 82, 49, 0]))
            try session.peer.finishWriting()
        }.value
        let firstAcknowledgement = try await session.sender.value
        return [("browser_clipboard_concurrent_busy_preserves_first_transfer_and_borrowed_second_fd",
                 request == browserClipboardExpectedFrame(session.text) && secondRejected && secondUntouched &&
                 firstStillActive && firstAcknowledgement == .completed)]
    }

    do {
        let transport = try BrowserClipboardTransport(timeout: 0.1)
        let sender = Task { try await transport.sendForTesting(text: "fixture", socketDescriptor: -1) }
        checks.append(("browser_clipboard_unavailable_descriptor_fails_before_transfer",
                       await browserClipboardHasFailure(sender, .unavailable) && transport.isSettled))
    } catch { checks.append(("browser_clipboard_unavailable_descriptor_fixture_failed", false)) }
    return checks
}

private func browserClipboardExpectedFrame(_ text: String) -> Data {
    let payload = Data(text.utf8)
    let length = UInt32(payload.count)
    var frame = Data([66, 80, 84, 49, UInt8((length >> 24) & 255), UInt8((length >> 16) & 255),
                      UInt8((length >> 8) & 255), UInt8(length & 255)])
    frame.append(payload)
    return frame
}

private func browserClipboardIsFixedCode(_ value: String) -> Bool {
    value.hasPrefix("BROWSER_PASTE_") && value.utf8.allSatisfy { (65...90).contains($0) || $0 == 95 }
}

private func browserClipboardHasFailure(_ sender: Task<BrowserClipboardTransport.Acknowledgement, Error>,
                                       _ expected: BrowserClipboardTransport.Failure) async -> Bool {
    do { _ = try await sender.value; return false }
    catch let failure as BrowserClipboardTransport.Failure { return failure == expected && browserClipboardIsFixedCode(failure.code) }
    catch { return false }
}

private func browserClipboardRunSession(_ name: String, text: String = "clipboard-local-fixture", timeout: TimeInterval = 1,
                                       checks: inout [(String, Bool)],
                                       body: (BrowserClipboardCheckSession) async throws -> [(String, Bool)]) async {
    do {
        let session = try BrowserClipboardCheckSession(text: text, timeout: timeout)
        do { checks.append(contentsOf: try await body(session)) }
        catch { checks.append(("browser_clipboard_\(name)_fixture_failed", false)) }
        session.sender.cancel()
        session.transport.cancel()
        _ = await session.sender.result
        checks.append(("browser_clipboard_\(name)_settled_and_borrowed_descriptor_retained",
                       session.transport.isSettled && session.client.isOpen))
    } catch { checks.append(("browser_clipboard_\(name)_fixture_setup_failed", false)) }
}

private final class BrowserClipboardCheckSession: @unchecked Sendable {
    let text: String
    let transport: BrowserClipboardTransport
    let client: BrowserClipboardCheckSocket
    let peer: BrowserClipboardCheckSocket
    let sender: Task<BrowserClipboardTransport.Acknowledgement, Error>

    init(text: String, timeout: TimeInterval) throws {
        let transport = try BrowserClipboardTransport(timeout: timeout)
        let pair = try BrowserClipboardCheckSocket.pair()
        self.text = text
        self.transport = transport
        client = pair.client
        peer = pair.peer
        sender = Task { try await transport.sendForTesting(text: text, socketDescriptor: pair.client.descriptor) }
    }

    deinit {
        sender.cancel()
        transport.cancel()
    }
}

private enum BrowserClipboardCheckError: Error {
    case socketFailure
    case deadline
    case excessiveFrame
}

private final class BrowserClipboardCheckSocket: @unchecked Sendable {
    let descriptor: Int32

    init(owning descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }

    var isOpen: Bool { fcntl(descriptor, F_GETFD) >= 0 }

    var hasReadableEvent: Bool {
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&event, 1, 0) > 0 && (event.revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL)) != 0
    }

    static func pair() throws -> (client: BrowserClipboardCheckSocket, peer: BrowserClipboardCheckSocket) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw BrowserClipboardCheckError.socketFailure }
        do {
            for descriptor in descriptors {
                let flags = fcntl(descriptor, F_GETFL)
                var noSigPipe: Int32 = 1
                guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                      setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                                 socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw BrowserClipboardCheckError.socketFailure }
            }
            return (BrowserClipboardCheckSocket(owning: descriptors[0]), BrowserClipboardCheckSocket(owning: descriptors[1]))
        } catch {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
            throw error
        }
    }

    func finishWriting() throws {
        guard shutdown(descriptor, SHUT_WR) == 0 else { throw BrowserClipboardCheckError.socketFailure }
    }

    func readUntilEOF(timeout: TimeInterval = 2) throws -> Data {
        let deadline = browserClipboardCheckNow() + timeout
        var frame = Data()
        var bytes = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = recv(descriptor, &bytes, bytes.count, 0)
            if count > 0 {
                frame.append(contentsOf: bytes.prefix(count))
                guard frame.count <= BrowserClipboardTransport.maximumTextBytes + 8 else { throw BrowserClipboardCheckError.excessiveFrame }
                continue
            }
            if count == 0 { return frame }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { throw BrowserClipboardCheckError.socketFailure }
            try waitFor(Int16(POLLIN), deadline: deadline)
        }
    }

    func write(_ data: Data, timeout: TimeInterval = 2) throws {
        let deadline = browserClipboardCheckNow() + timeout
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes {
                Darwin.send(descriptor, $0.baseAddress!.advanced(by: written), data.count - written, 0)
            }
            if count > 0 { written += count; continue }
            if count < 0 && errno == EINTR { continue }
            guard count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else { throw BrowserClipboardCheckError.socketFailure }
            try waitFor(Int16(POLLOUT), deadline: deadline)
        }
    }

    private func waitFor(_ events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - browserClipboardCheckNow()
            guard remaining > 0 else { throw BrowserClipboardCheckError.deadline }
            var event = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = poll(&event, 1, Int32(min(100, max(1, ceil(remaining * 1000)))))
            if ready > 0 {
                guard event.revents & Int16(POLLNVAL) == 0 else { throw BrowserClipboardCheckError.socketFailure }
                return
            }
            if ready < 0 && errno != EINTR { throw BrowserClipboardCheckError.socketFailure }
        }
    }
}

private func browserClipboardCheckNow() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
