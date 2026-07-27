// SPDX-License-Identifier: Apache-2.0
import Foundation

/// How the host reaches the on-device bridge.
///
/// The Android backend gets this for free: `adb forward` gives every
/// verb a loopback port regardless of whether the device is on USB or
/// Wi-Fi. iOS has no equivalent, so there are two genuinely different
/// paths and the client picks one per session:
///
///   - ``USBMuxTransport`` — over the USB cable, through the `usbmuxd`
///     socket every Mac with Xcode already runs. Preferred: it works
///     with no network configuration, survives the phone changing
///     Wi-Fi networks, and cannot be reached by anything else on the
///     LAN.
///   - ``NetworkTransport`` — a plain TCP connection to an address the
///     runner reported at startup. The only option when the phone is
///     not plugged in.
public protocol BridgeTransport: Sendable {
    /// Human-readable description used in errors and `ping` output.
    var describedEndpoint: String { get }

    func send(_ request: BridgeHTTPRequest) throws -> BridgeHTTPResponse
}

public struct BridgeHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let body: Data?
    public let contentType: String?
    public let bearerToken: String?
    public let timeout: TimeInterval

    public init(
        method: String,
        path: String,
        body: Data? = nil,
        contentType: String? = nil,
        bearerToken: String? = nil,
        timeout: TimeInterval = 30
    ) {
        self.method = method
        self.path = path
        self.body = body
        self.contentType = contentType
        self.bearerToken = bearerToken
        self.timeout = timeout
    }

    /// Serialised HTTP/1.1 request bytes. `Host` is a placeholder — the
    /// bridge routes on path alone and never inspects it — but omitting
    /// it makes the request illegal HTTP/1.1, and some proxies people
    /// run locally will drop it.
    public func serialized(host: String) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: \(host)\r\n"
        if let bearerToken { head += "Authorization: Bearer \(bearerToken)\r\n" }
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body?.count ?? 0)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        return out
    }
}

public struct BridgeHTTPResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// Minimal HTTP/1.1 response reader for the raw-socket transports.
///
/// The bridge answers every request with `Connection: close` and an
/// explicit `Content-Length` (see `ios-bridge/.../HTTPMessage.swift`),
/// so this only has to handle that one shape — no chunked encoding, no
/// keep-alive, no redirects. Reading to EOF is the fallback for a
/// response that somehow arrives without a length.
public enum BridgeHTTPResponseParser {
    public enum ParseError: Error, LocalizedError {
        case truncatedHead
        case malformedStatusLine(String)

        public var errorDescription: String? {
            switch self {
            case .truncatedHead:
                return "The bridge closed the connection before sending a complete HTTP response."
            case .malformedStatusLine(let line):
                return "The bridge sent an unparseable HTTP status line: \(line)"
            }
        }
    }

    /// Splits `data` into status + body. Returns nil when the header
    /// terminator has not arrived, so a socket reader can keep going.
    public static func parse(_ data: Data) throws -> BridgeHTTPResponse? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: terminator) else { return nil }

        let headData = data[data.startIndex..<range.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else {
            throw ParseError.truncatedHead
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw ParseError.truncatedHead }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw ParseError.malformedStatusLine(statusLine)
        }

        let body = Data(data[range.upperBound...])
        guard let expected = contentLength(lines) else {
            // No Content-Length: the caller reads until EOF and calls us
            // again with everything it got.
            return BridgeHTTPResponse(status: status, body: body)
        }
        guard body.count >= expected else { return nil }
        return BridgeHTTPResponse(status: status, body: body.prefix(expected))
    }

    /// `true` when a response without `Content-Length` needs an
    /// EOF-terminated read.
    public static func needsReadToEOF(_ data: Data) -> Bool {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        guard let head = String(data: data[data.startIndex..<range.lowerBound], encoding: .utf8) else { return false }
        return contentLength(head.components(separatedBy: "\r\n")) == nil
    }

    private static func contentLength(_ lines: [String]) -> Int? {
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            guard line[..<colon].lowercased() == "content-length" else { continue }
            return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
