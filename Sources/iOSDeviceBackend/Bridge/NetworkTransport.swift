// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Reaches the on-device bridge over TCP, using an address the runner
/// reported on its ready line.
///
/// Used when the phone is not on USB. The runner advertises every
/// non-loopback, non-link-local address it has; we try them in order
/// and remember the first that answers, because a phone typically has
/// several (Wi-Fi, a VPN's tunnel, a carrier interface) and only one is
/// reachable from this Mac.
public struct NetworkTransport: BridgeTransport {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var describedEndpoint: String { "tcp://\(bracketed(host)):\(port)" }

    public func send(_ request: BridgeHTTPRequest) throws -> BridgeHTTPResponse {
        let fd = try Self.connect(host: host, port: port, timeout: min(request.timeout, 5))
        return try SocketIO.exchange(fd: fd, request: request, host: "\(bracketed(host)):\(port)")
    }

    /// IPv6 literals need brackets in a `Host:` header and in anything
    /// a user might paste into a browser.
    private func bracketed(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }

    static func connect(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &info)
        guard status == 0, let first = info else {
            throw TransportError.noRoute(
                udid: host,
                detail: "cannot resolve \(host): \(String(cString: gai_strerror(status)))"
            )
        }
        defer { freeaddrinfo(info) }

        var lastErrno: Int32 = ECONNREFUSED
        for candidate in sequence(first: first, next: { $0.pointee.ai_next }) {
            let fd = socket(candidate.pointee.ai_family, candidate.pointee.ai_socktype, candidate.pointee.ai_protocol)
            if fd < 0 { lastErrno = errno; continue }
            SocketIO.setReceiveTimeout(fd, seconds: timeout)
            if Darwin.connect(fd, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0 {
                return fd
            }
            lastErrno = errno
            close(fd)
        }
        throw TransportError.noRoute(
            udid: host,
            detail: "connect to \(host):\(port) failed: \(String(cString: strerror(lastErrno)))"
        )
    }

    /// Returns the first address that answers `/ping`, or nil.
    ///
    /// The runner cannot know which of its interfaces this Mac can see,
    /// so probing is the only honest way to pick. Each attempt is
    /// short: an unreachable address on a local network fails fast, and
    /// a routable-but-wrong one is the case worth bounding.
    public static func firstReachable(
        addresses: [String],
        port: UInt16,
        perAddressTimeout: TimeInterval = 2
    ) -> String? {
        for address in addresses {
            let transport = NetworkTransport(host: address, port: port)
            let request = BridgeHTTPRequest(method: "GET", path: "/ping", timeout: perAddressTimeout)
            if let response = try? transport.send(request), response.status == 200 {
                return address
            }
        }
        return nil
    }
}
