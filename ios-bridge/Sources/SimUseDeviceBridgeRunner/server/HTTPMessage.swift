// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Parsed HTTP/1.1 request. Mirrors what the Android bridge's
/// `HttpServer.parseRequest` produces: method, path, a flat
/// `params` map that merges the query string with a form-encoded or
/// JSON body, and lowercased header keys.
struct HTTPRequest {
    let method: String
    let path: String
    let params: [String: String]
    let headers: [String: String]
}

/// Status + body pair. Every response closes the connection
/// (`Connection: close`), matching the Android bridge, so the host's
/// client never has to deal with keep-alive framing.
struct HTTPResponse {
    let status: Int
    let body: Data
    let contentType: String

    init(status: Int, body: Data, contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    init(status: Int, json: String) {
        self.init(status: status, body: Data(json.utf8))
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Status"
        }
    }
}

enum HTTPParser {
    /// Largest request we will buffer. Only `/keyboard/input` and
    /// `/paste` carry a body of any size (base64 text); 4 MiB is far
    /// beyond any realistic payload and bounds a hostile client that
    /// got past the bearer check.
    static let maxBodyBytes = 4 * 1024 * 1024

    /// Splits `data` at the header/body boundary. Returns nil while the
    /// terminator has not arrived yet so the caller keeps reading.
    static func headerBoundary(in data: Data) -> Int? {
        let terminator = Data("\r\n\r\n".utf8)
        return data.range(of: terminator)?.upperBound
    }

    /// Parses a complete request. `body` may be empty for GETs.
    static func parse(head: String, body: Data) -> HTTPRequest? {
        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let (path, queryParams) = splitTarget(target)
        var params = queryParams
        for (key, value) in bodyParams(body, contentType: headers["content-type"] ?? "") {
            params[key] = value
        }

        return HTTPRequest(method: method, path: path, params: params, headers: headers)
    }

    static func splitTarget(_ target: String) -> (path: String, params: [String: String]) {
        guard let qIndex = target.firstIndex(of: "?") else {
            return (target, [:])
        }
        let path = String(target[..<qIndex])
        let query = String(target[target.index(after: qIndex)...])
        return (path, formDecode(query))
    }

    /// Body decoding accepts both shapes the host may send: a
    /// form-encoded string (what the Android bridge client uses) and a
    /// flat JSON object (more natural for the multi-stroke `/gesture`
    /// payload, where the value is itself a JSON array).
    static func bodyParams(_ body: Data, contentType: String) -> [String: String] {
        guard !body.isEmpty else { return [:] }
        if contentType.contains("json") {
            guard
                let object = try? JSONSerialization.jsonObject(with: body),
                let dict = object as? [String: Any]
            else { return [:] }
            var out: [String: String] = [:]
            for (key, value) in dict {
                out[key] = stringify(value)
            }
            return out
        }
        guard let text = String(data: body, encoding: .utf8) else { return [:] }
        return formDecode(text)
    }

    /// Nested containers are re-encoded as JSON text rather than
    /// flattened, so `strokes` survives the trip as the JSON array
    /// string that `GestureHandler` re-parses.
    private static func stringify(_ value: Any) -> String {
        switch value {
        case let text as String: return text
        case let flag as Bool: return flag ? "true" : "false"
        case let number as NSNumber: return number.stringValue
        default:
            guard
                let data = try? JSONSerialization.data(withJSONObject: value),
                let text = String(data: data, encoding: .utf8)
            else { return "" }
            return text
        }
    }

    static func formDecode(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = kv.first else { continue }
            let key = percentDecode(String(rawKey))
            let value = kv.count > 1 ? percentDecode(String(kv[1])) : ""
            out[key] = value
        }
        return out
    }

    /// `+` means space in `application/x-www-form-urlencoded`, which
    /// `removingPercentEncoding` alone does not handle. Base64 payloads
    /// contain `+`, so getting this wrong corrupts every `/paste` and
    /// `/keyboard/input` call that happens to encode one.
    private static func percentDecode(_ text: String) -> String {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
    }
}
