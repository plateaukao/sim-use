// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Blocking read/write helpers with a wall-clock deadline, shared by
/// both raw-socket transports.
///
/// `SO_RCVTIMEO` alone is not enough: it bounds a single `read`, not the
/// whole exchange, so a bridge dribbling one byte per timeout period
/// would hang the CLI indefinitely. Every loop here checks the deadline
/// as well.
enum SocketIO {
    enum IOError: Error, LocalizedError {
        case timedOut(String)
        case closed(String)
        case failed(String, Int32)

        var errorDescription: String? {
            switch self {
            case .timedOut(let what):
                return "Timed out while \(what)."
            case .closed(let what):
                return "The connection closed while \(what)."
            case .failed(let what, let code):
                return "\(what) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data, deadline: Date) throws {
        try data.withUnsafeBytes { raw in
            guard var pointer = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                guard Date() < deadline else { throw IOError.timedOut("sending the request") }
                let written = Darwin.write(fd, pointer, remaining)
                if written > 0 {
                    pointer += written
                    remaining -= written
                    continue
                }
                if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                if written == 0 { throw IOError.closed("sending the request") }
                throw IOError.failed("write", errno)
            }
        }
    }

    /// Reads until `isComplete` accepts the accumulated buffer, EOF, or
    /// the deadline. `isComplete` returning true stops the read without
    /// waiting for the peer to close — which matters because the bridge
    /// only closes after its own write completes.
    static func readUntil(
        _ fd: Int32,
        deadline: Date,
        isComplete: (Data) throws -> Bool
    ) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            if try isComplete(buffer) { return buffer }
            guard Date() < deadline else { throw IOError.timedOut("reading the response") }

            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                continue
            }
            if n == 0 {
                // EOF. Give `isComplete` a last look — a response with no
                // Content-Length is only complete at EOF.
                return buffer
            }
            if errno == EINTR || errno == EAGAIN { continue }
            throw IOError.failed("read", errno)
        }
    }

    /// Applies a receive timeout so a single blocking `read` cannot
    /// outlive the deadline by more than one slice.
    static func setReceiveTimeout(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Runs one HTTP exchange over an already-connected socket and
    /// closes it. Both transports converge here so the framing rules
    /// live in exactly one place.
    static func exchange(
        fd: Int32,
        request: BridgeHTTPRequest,
        host: String
    ) throws -> BridgeHTTPResponse {
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(request.timeout)
        setReceiveTimeout(fd, seconds: min(request.timeout, 5))

        try writeAll(fd, request.serialized(host: host), deadline: deadline)

        // Stop as soon as Content-Length is satisfied; a response with no
        // Content-Length is only complete at EOF, so keep reading and let
        // the loop end on close.
        let buffer = try readUntil(fd, deadline: deadline) { data in
            guard try BridgeHTTPResponseParser.parse(data) != nil else { return false }
            return !BridgeHTTPResponseParser.needsReadToEOF(data)
        }
        guard let response = try BridgeHTTPResponseParser.parse(buffer) else {
            throw IOError.closed("waiting for a complete HTTP response")
        }
        return response
    }
}
