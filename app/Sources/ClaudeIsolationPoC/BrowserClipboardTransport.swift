import Darwin
import Foundation
import Virtualization

/// One explicitly requested host-to-guest text paste. It borrows the supplied
/// connection, owns only a duplicate fd, and never records text or reply data.
final class BrowserClipboardTransport: @unchecked Sendable {
    static let port: UInt32 = 40127
    static let maximumTextBytes = 65_536

    enum Acknowledgement: UInt8, Sendable {
        case completed = 0
        case invalidPayload = 1
        case busy = 2
        case firefoxNotFocused = 3
        case clipboardFailed = 4
        case guestTimeout = 5

        var code: String {
            switch self {
            case .completed: return "BROWSER_PASTE_COMPLETED"
            case .invalidPayload: return "BROWSER_PASTE_INVALID_PAYLOAD"
            case .busy: return "BROWSER_PASTE_GUEST_BUSY"
            case .firefoxNotFocused: return "BROWSER_PASTE_FIREFOX_NOT_FOCUSED"
            case .clipboardFailed: return "BROWSER_PASTE_GUEST_CLIPBOARD_FAILED"
            case .guestTimeout: return "BROWSER_PASTE_GUEST_TIMEOUT"
            }
        }
    }

    enum Failure: String, Error, Sendable {
        case invalidText = "BROWSER_PASTE_INVALID_TEXT"
        case unavailable = "BROWSER_PASTE_CONNECTION_UNAVAILABLE"
        case busy = "BROWSER_PASTE_TRANSPORT_BUSY"
        case invalidResponse = "BROWSER_PASTE_RESPONSE_INVALID"
        case timedOut = "BROWSER_PASTE_TRANSPORT_TIMEOUT"
        case cancelled = "BROWSER_PASTE_CANCELLED"
        case ioFailure = "BROWSER_PASTE_TRANSPORT_IO_FAILED"
        case invalidTimeout = "BROWSER_PASTE_TIMEOUT_INVALID"

        var code: String { rawValue }
    }

    private let timeout: TimeInterval
    private let workers = DispatchQueue(label: "claude.browser.clipboard.transport", attributes: .concurrent)
    private let lock = NSLock()
    private var current: BrowserClipboardTransfer?

    init(timeout: TimeInterval = 8) throws {
        guard timeout.isFinite, (0.01...8).contains(timeout) else { throw Failure.invalidTimeout }
        self.timeout = timeout
    }

    static func validate(text: String) throws {
        _ = try validatedBytes(text)
    }

    var isSettled: Bool {
        lock.lock(); defer { lock.unlock() }
        return current == nil
    }

    /// The main queue only duplicates the VZ-owned fd and prepares a <=64 KiB
    /// frame. Socket reads, writes, and deadline polling run off it; cancellation
    /// may perform a nonblocking shutdown to wake the I/O worker immediately.
    /// The caller retains/closes its original VZ connection on the VM queue.
    @MainActor
    func send(text: String, connection: VZVirtioSocketConnection) async throws -> Acknowledgement {
        guard connection.destinationPort == Self.port else { throw Failure.unavailable }
        let transfer = try prepare(text: text, descriptor: connection.fileDescriptor)
        return try await perform(transfer)
    }

    /// The fixture retains ownership of socketDescriptor, including on failure.
    /// The transport duplicates it just as it duplicates the VZ descriptor.
    func sendForTesting(text: String, socketDescriptor: Int32) async throws -> Acknowledgement {
        let transfer = try prepare(text: text, descriptor: socketDescriptor)
        return try await perform(transfer)
    }

    /// This does not close a descriptor while its worker may be using it.
    /// Await the send task, or poll isSettled asynchronously, before retiring.
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        current?.requestCancel()
    }

    private static func validatedBytes(_ text: String) throws -> Data {
        // Reading at most one byte beyond the bound avoids allocating/scanning
        // an arbitrarily large clipboard value just to reject it.
        let bytes = Data(text.utf8.prefix(maximumTextBytes + 1))
        guard !bytes.isEmpty, bytes.count <= maximumTextBytes, !bytes.contains(0) else { throw Failure.invalidText }
        return bytes
    }

    private func prepare(text: String, descriptor: Int32) throws -> BrowserClipboardTransfer {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let payload = try Self.validatedBytes(text)
        guard !Task.isCancelled else { throw Failure.cancelled }
        lock.lock(); defer { lock.unlock() }
        guard current == nil else { throw Failure.busy }
        guard descriptor >= 0 else { throw Failure.unavailable }
        let ownedDescriptor = Darwin.dup(descriptor)
        guard ownedDescriptor >= 0 else { throw Failure.unavailable }
        let flags = fcntl(ownedDescriptor, F_GETFL)
        var noPipe: Int32 = 1
        var noLinger = linger(l_onoff: 0, l_linger: 0)
        guard flags >= 0, fcntl(ownedDescriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(ownedDescriptor, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(ownedDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(ownedDescriptor, SOL_SOCKET, SO_LINGER, &noLinger, socklen_t(MemoryLayout<linger>.size)) == 0 else {
            _ = Darwin.close(ownedDescriptor)
            throw Failure.unavailable
        }
        let count = UInt32(payload.count)
        var frame = Data([66, 80, 84, 49, UInt8((count >> 24) & 255), UInt8((count >> 16) & 255),
                          UInt8((count >> 8) & 255), UInt8(count & 255)])
        frame.append(payload)
        let transfer = BrowserClipboardTransfer(descriptor: ownedDescriptor, frame: frame, deadline: startedAt + timeout)
        current = transfer
        return transfer
    }

    private func perform(_ transfer: BrowserClipboardTransfer) async throws -> Acknowledgement {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Acknowledgement, Error>) in
                workers.async { [self, transfer] in
                    let result: Result<Acknowledgement, Failure>
                    do {
                        let acknowledgement = try run(transfer)
                        try transfer.checkRunning()
                        result = .success(acknowledgement)
                    } catch let failure as Failure {
                        result = .failure(transfer.isCancelled ? .cancelled : failure)
                    } catch {
                        // Never attach OS errors, reply data, or original text.
                        result = .failure(transfer.isCancelled ? .cancelled : .ioFailure)
                    }
                    transfer.closeOwnedDescriptor()
                    lock.lock()
                    if current === transfer { current = nil }
                    lock.unlock()
                    // Success and failure both resume only after fd ownership
                    // and the in-memory payload have been retired.
                    switch result {
                    case .success(let acknowledgement): continuation.resume(returning: acknowledgement)
                    case .failure(let failure): continuation.resume(throwing: failure)
                    }
                }
            }
        } onCancel: {
            // Cancel this transfer specifically. A late cancellation handler
            // can never shut down a later paste started on the same instance.
            transfer.requestCancel()
        }
    }

    private func run(_ transfer: BrowserClipboardTransfer) throws -> Acknowledgement {
        let descriptor = transfer.descriptor
        let frame = transfer.frame
        var sent = 0
        while sent < frame.count {
            try wait(descriptor, events: Int16(POLLOUT), transfer: transfer)
            let count = frame.withUnsafeBytes { bytes in
                Darwin.send(descriptor, bytes.baseAddress!.advanced(by: sent), frame.count - sent, 0)
            }
            if count > 0 { sent += count }
            else if count == 0 { throw Failure.ioFailure }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw Failure.ioFailure }
        }
        try transfer.checkRunning()
        guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else { throw Failure.ioFailure }

        var reply = [UInt8](repeating: 0, count: 5)
        var received = 0
        while received < reply.count {
            try wait(descriptor, events: Int16(POLLIN), transfer: transfer)
            let remainingReplyBytes = reply.count - received
            let count = reply.withUnsafeMutableBytes { bytes in
                Darwin.recv(descriptor, bytes.baseAddress!.advanced(by: received), remainingReplyBytes, 0)
            }
            if count > 0 { received += count }
            else if count == 0 { throw Failure.invalidResponse }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw Failure.ioFailure }
        }
        guard reply.prefix(4).elementsEqual([66, 80, 82, 49]),
              let acknowledgement = Acknowledgement(rawValue: reply[4]) else { throw Failure.invalidResponse }

        // A single fixed ACK and EOF are the whole response. Detect extra bytes
        // with a one-byte buffer; do not collect, decode, or expose a body.
        while true {
            try wait(descriptor, events: Int16(POLLIN), transfer: transfer)
            var extra: UInt8 = 0
            let count = Darwin.recv(descriptor, &extra, 1, 0)
            if count > 0 { throw Failure.invalidResponse }
            if count == 0 { return acknowledgement }
            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { throw Failure.ioFailure }
        }
    }

    private func wait(_ descriptor: Int32, events: Int16, transfer: BrowserClipboardTransfer) throws {
        while true {
            try transfer.checkRunning()
            let remaining = transfer.deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw Failure.timedOut }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, Int32(min(250, max(1, ceil(remaining * 1000)))))
            try transfer.checkRunning()
            if result > 0 {
                guard item.revents & Int16(POLLNVAL) == 0 else { throw Failure.ioFailure }
                if item.revents & (events | Int16(POLLHUP | POLLERR)) != 0 { return }
            } else if result < 0 && errno != EINTR { throw Failure.ioFailure }
        }
    }
}

/// Only the I/O worker closes its duplicate. Cancellation merely shuts it down
/// under the same lock, so a reused fd can never be hit by a late cancellation.
private final class BrowserClipboardTransfer: @unchecked Sendable {
    let descriptor: Int32
    let deadline: TimeInterval
    private(set) var frame: Data
    private let lock = NSLock()
    private var cancelled = false
    private var closed = false

    init(descriptor: Int32, frame: Data, deadline: TimeInterval) {
        self.descriptor = descriptor
        self.frame = frame
        self.deadline = deadline
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func checkRunning() throws {
        if isCancelled { throw BrowserClipboardTransport.Failure.cancelled }
    }

    func requestCancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if !closed { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
    }

    func closeOwnedDescriptor() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        _ = Darwin.close(descriptor)
        frame.removeAll(keepingCapacity: false)
    }
}
