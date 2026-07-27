// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Minimal HTTP/1.1 server on a BSD socket accept loop, structurally the
/// same as the Android bridge's `HttpServer.kt`: bind, listen, hand each
/// accepted connection to a bounded worker pool, answer with
/// `Connection: close`.
///
/// Network.framework would be the modern choice, but a blocking accept
/// loop is a better fit here — the runner is a test process with a
/// thread to spare, there is no TLS, and the synchronous shape keeps the
/// hand-off to `SerialWorkQueue` obvious.
final class HTTPServer {
    typealias Handler = (HTTPRequest) -> HTTPResponse

    private let port: UInt16
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private let workers: DispatchQueue

    /// Matches the Android bridge's `FixedThreadPool(4)`. Requests
    /// serialize on `SerialWorkQueue` anyway; the pool only bounds how
    /// many sockets can be mid-parse concurrently.
    private static let maxConcurrentConnections = 4

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
        self.workers = DispatchQueue(
            label: "com.linecorp.simuse.devicebridge.http",
            attributes: .concurrent
        )
    }

    enum StartError: Error, CustomStringConvertible {
        case socketFailed(Int32)
        case bindFailed(UInt16, Int32)
        case listenFailed(Int32)

        var description: String {
            switch self {
            case .socketFailed(let errno):
                return "socket() failed: \(String(cString: strerror(errno)))"
            case .bindFailed(let port, let errno):
                return "bind(:\(port)) failed: \(String(cString: strerror(errno))). Another bridge (or WebDriverAgent) may already own the port."
            case .listenFailed(let errno):
                return "listen() failed: \(String(cString: strerror(errno)))"
            }
        }
    }

    func start() throws {
        // Dual-stack: bind `::` with IPV6_V6ONLY off so one socket
        // serves both the usbmux path (which lands on IPv4 loopback)
        // and direct Wi-Fi clients on either family.
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socketFailed(errno) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var off: Int32 = 0
        setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindResult == 0 else {
            let saved = errno
            close(fd)
            throw StartError.bindFailed(port, saved)
        }

        guard Darwin.listen(fd, Int32(Self.maxConcurrentConnections * 2)) == 0 else {
            let saved = errno
            close(fd)
            throw StartError.listenFailed(saved)
        }

        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "simuse-bridge-accept"
        thread.start()
        acceptThread = thread
    }

    func stop() {
        let fd = listenFD
        listenFD = -1
        if fd >= 0 { close(fd) }
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let client = Darwin.accept(listenFD, nil, nil)
            if client < 0 {
                // EINTR is routine; anything else on a closed listener
                // means `stop()` won the race and we should unwind.
                if errno == EINTR { continue }
                if listenFD < 0 { return }
                continue
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            workers.async { [weak self] in
                self?.serve(client)
                close(client)
            }
        }
    }

    private func serve(_ fd: Int32) {
        guard let request = readRequest(fd) else {
            write(fd, HTTPResponse(status: 400, json: Envelope.error(code: "malformed_request")))
            return
        }
        write(fd, handler(request))
    }

    private func readRequest(_ fd: Int32) -> HTTPRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)

        var headEnd: Int?
        while headEnd == nil {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > HTTPParser.maxBodyBytes { return nil }
            headEnd = HTTPParser.headerBoundary(in: buffer)
        }
        guard let boundary = headEnd else { return nil }

        // `boundary` includes the blank-line terminator; drop the
        // trailing CRLFCRLF before parsing the head as text.
        let headData = buffer.prefix(boundary - 4)
        guard let head = String(data: headData, encoding: .utf8) else { return nil }

        var body = Data(buffer.suffix(from: boundary))
        let expected = contentLength(in: head) ?? 0
        guard expected <= HTTPParser.maxBodyBytes else { return nil }
        while body.count < expected {
            let n = read(fd, &chunk, min(chunk.count, expected - body.count))
            guard n > 0 else { return nil }
            body.append(contentsOf: chunk[0..<n])
        }

        return HTTPParser.parse(head: head, body: body)
    }

    private func contentLength(in head: String) -> Int? {
        for line in head.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            guard line[..<colon].lowercased() == "content-length" else { continue }
            return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private func write(_ fd: Int32, _ response: HTTPResponse) {
        var data = response.serialized()
        data.withUnsafeBytes { raw in
            guard var pointer = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                // A client that hung up mid-write (the CLI timed out and
                // closed) is normal; drop the rest rather than spinning.
                guard written > 0 else { return }
                pointer += written
                remaining -= written
            }
        }
    }
}
