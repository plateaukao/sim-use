// SPDX-License-Identifier: Apache-2.0
import Foundation

/// JSON envelope shared with the Android bridge so one host-side decoder
/// (`BridgeEnvelope`) serves both platforms:
///
///   success: `{"status":"success"}` or `{"status":"success","result":<inline JSON>}`
///   error:   `{"status":"error","code":"…","error":"…"}`
///
/// `result` is a real JSON value, never a JSON-encoded string.
enum Envelope {
    static func success(_ result: Any? = nil, extra: [String: Any] = [:]) -> String {
        var payload: [String: Any] = ["status": "success"]
        if let result { payload["result"] = result }
        for (key, value) in extra { payload[key] = value }
        return encode(payload)
    }

    static func error(code: String, message: String? = nil) -> String {
        var payload: [String: Any] = ["status": "error", "code": code]
        if let message { payload["error"] = message }
        return encode(payload)
    }

    /// Falls back to a hand-built error string rather than throwing:
    /// a serialization failure deep in a handler must still produce a
    /// well-formed envelope, or the host sees a transport error and
    /// reports something unrelated to the real cause.
    private static func encode(_ payload: [String: Any]) -> String {
        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return #"{"status":"error","code":"serialization_failed"}"#
        }
        return text
    }
}
