// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Host-side client for the on-device bridge served by
/// `ios-bridge/Sources/SimUseDeviceBridgeRunner`.
///
/// Shares the Android bridge's envelope (`{status, result, …}`) and
/// endpoint names, so the two backends read almost identically. The one
/// deliberate divergence is `/a11y_tree_full`, whose `result` is an
/// array of **iOS** accessibility elements — the same shape idb returns
/// for the Simulator — which is what lets the whole
/// `OutlineFormatter` / selector stack be reused unchanged.
public final class IOSDeviceBridgeClient: @unchecked Sendable {

    /// Bumped together with `BridgeVersion.protocolVersion` in the
    /// runner. Independent of the Android bridge's number: the two
    /// protocols share an envelope but not a tree shape.
    public static let expectedProtocolVersion = 1

    public let udid: String
    private let transport: BridgeTransport
    private let token: String

    private let lock = NSLock()
    private var verifiedProtocolVersion = false

    public init(udid: String, transport: BridgeTransport, token: String) {
        self.udid = udid
        self.transport = transport
        self.token = token
    }

    public var describedEndpoint: String { transport.describedEndpoint }

    /// Builds a client from a stored session, picking the transport the
    /// same way `init` did: USB when the device is attached, otherwise
    /// the address that last answered.
    public static func fromSession(
        _ session: IOSDeviceBridgeSession,
        preferUSB: Bool = true
    ) throws -> IOSDeviceBridgeClient {
        let transport = try resolveTransport(for: session, preferUSB: preferUSB)
        return IOSDeviceBridgeClient(udid: session.udid, transport: transport, token: session.token)
    }

    static func resolveTransport(
        for session: IOSDeviceBridgeSession,
        preferUSB: Bool
    ) throws -> BridgeTransport {
        if preferUSB, USBMuxTransport.attachedUDIDs().contains(USBMuxTransport.normalizeUDID(session.udid)) {
            return USBMuxTransport(udid: session.udid, port: session.port)
        }
        // The remembered host first — it worked last time and re-probing
        // every address on every invocation would add seconds to a CLI
        // whose whole point is being fast.
        if let preferred = session.preferredHost {
            return NetworkTransport(host: preferred, port: session.port)
        }
        if let reachable = NetworkTransport.firstReachable(addresses: session.addresses, port: session.port) {
            return NetworkTransport(host: reachable, port: session.port)
        }
        throw TransportError.noRoute(
            udid: session.udid,
            detail: """
                the device is not attached over USB and none of the addresses the bridge reported \
                (\(session.addresses.joined(separator: ", "))) answered on port \(session.port). \
                Plug the device in, put it back on the same network, or re-run `sim-use ios-device init`
                """
        )
    }

    // MARK: - Endpoints

    public struct PingResult: Sendable {
        public let protocolVersion: Int
        public let bridgeVersion: String
    }

    @discardableResult
    public func ping(force: Bool = false) throws -> PingResult {
        lock.lock()
        let alreadyVerified = verifiedProtocolVersion
        lock.unlock()
        if alreadyVerified && !force {
            return PingResult(protocolVersion: Self.expectedProtocolVersion, bridgeVersion: "")
        }

        let json = try requestJSON(method: "GET", path: "/ping", requiresAuth: false)
        let protocolVersion = json["protocol_version"] as? Int ?? -1
        let bridgeVersion = json["bridge_version"] as? String ?? "unknown"
        guard protocolVersion == Self.expectedProtocolVersion else {
            throw IOSDeviceBridgeError.protocolMismatch(
                expected: Self.expectedProtocolVersion,
                actual: protocolVersion,
                bridgeVersion: bridgeVersion
            )
        }
        lock.lock()
        verifiedProtocolVersion = true
        lock.unlock()
        return PingResult(protocolVersion: protocolVersion, bridgeVersion: bridgeVersion)
    }

    public struct TreeResult: Sendable {
        /// Raw `result` array bytes, re-encoded so callers can decode
        /// them into `AccessibilityElement` (the Simulator's type) or
        /// pass them through to `--json`.
        public let elementsJSON: Data
        public let appBundleID: String?
        public let appName: String?
        public let display: (width: Double, height: Double)?
        /// Apps the bridge tried and skipped, for diagnostics.
        public let skipped: [String]
    }

    public func fetchTree(filter: Bool = false, bundleID: String? = nil, timeout: TimeInterval = 40) throws -> TreeResult {
        var query = "filter=\(filter)"
        if let bundleID { query += "&bundle_id=\(Self.escape(bundleID))" }
        let json = try requestJSON(method: "GET", path: "/a11y_tree_full?\(query)", timeout: timeout)

        guard let elements = json["result"] as? [[String: Any]] else {
            throw IOSDeviceBridgeError.malformedEnvelope("`result` was not an array of accessibility elements")
        }
        let elementsJSON = try JSONSerialization.data(withJSONObject: elements)

        let app = json["app"] as? [String: Any]
        var display: (width: Double, height: Double)?
        if
            let raw = json["display"] as? [String: Any],
            let width = (raw["width"] as? NSNumber)?.doubleValue,
            let height = (raw["height"] as? NSNumber)?.doubleValue
        {
            display = (width, height)
        }

        return TreeResult(
            elementsJSON: elementsJSON,
            appBundleID: app?["bundle_id"] as? String,
            appName: app?["name"] as? String,
            display: display,
            skipped: json["skipped"] as? [String] ?? []
        )
    }

    public func screenshot(scale: Double? = nil, timeout: TimeInterval = 60) throws -> Data {
        var path = "/screenshot"
        if let scale, scale > 0, scale < 1 { path += "?scale=\(scale)" }
        let json = try requestJSON(method: "GET", path: path, timeout: timeout)
        guard
            let base64 = json["result"] as? String,
            let data = Data(base64Encoded: base64)
        else {
            throw IOSDeviceBridgeError.malformedEnvelope("`result` was not base64 PNG data")
        }
        return data
    }

    public func tap(x: Double, y: Double, durationMilliseconds: Int? = nil) throws {
        var fields = ["x": String(x), "y": String(y)]
        if let durationMilliseconds { fields["duration"] = String(durationMilliseconds) }
        _ = try requestJSON(method: "POST", path: "/tap", form: fields)
    }

    public func swipe(
        startX: Double, startY: Double,
        endX: Double, endY: Double,
        durationMilliseconds: Int
    ) throws {
        _ = try requestJSON(method: "POST", path: "/swipe", form: [
            "startX": String(startX), "startY": String(startY),
            "endX": String(endX), "endY": String(endY),
            "duration": String(durationMilliseconds),
        ])
    }

    /// Multi-stroke gestures. `strokes` is passed through as JSON text
    /// in the same shape the Android bridge accepts, so the CLI's
    /// gesture presets encode once for both platforms.
    public func gesture(strokesJSON: String, timeout: TimeInterval = 40) throws {
        _ = try requestJSON(method: "POST", path: "/gesture", form: ["strokes": strokesJSON], timeout: timeout)
    }

    /// Returns whether the field was actually emptied when `clear` was
    /// requested. The bridge verifies rather than assumes — a partial
    /// clear silently prefixes the new text onto the old.
    @discardableResult
    public func type(text: String, clear: Bool) throws -> Bool {
        let json = try requestJSON(method: "POST", path: "/keyboard/input", form: [
            "base64_text": Data(text.utf8).base64EncodedString(),
            "clear": clear ? "true" : "false",
        ], timeout: max(30, Double(text.count) * 0.1))
        guard clear else { return true }
        return (json["result"] as? [String: Any])?["cleared"] as? Bool ?? true
    }

    public func key(_ name: String) throws {
        _ = try requestJSON(method: "POST", path: "/keyboard/key", form: ["key": name])
    }

    public func button(_ name: String) throws {
        _ = try requestJSON(method: "POST", path: "/button", form: ["name": name])
    }

    public struct KeyboardState: Sendable {
        public let visible: Bool
        public let owner: String?
        public let frame: (x: Double, y: Double, width: Double, height: Double)?
        /// Which of the bridge's detection strategies answered —
        /// `query`, `snapshot`, `keys`, `focus`, or `none`. Worth
        /// surfacing because a third-party keyboard extension is
        /// invisible to the first three, and knowing which one fired is
        /// the difference between trusting the answer and re-checking
        /// it. `focus` in particular proves the keyboard is up without
        /// being able to say where.
        public let detection: String
    }

    public func keyboardState() throws -> KeyboardState {
        let json = try requestJSON(method: "GET", path: "/keyboard/state")
        guard let result = json["result"] as? [String: Any] else {
            throw IOSDeviceBridgeError.malformedEnvelope("`result` was not a keyboard-state object")
        }
        var frame: (x: Double, y: Double, width: Double, height: Double)?
        if
            let raw = result["frame"] as? [String: Any],
            let x = (raw["x"] as? NSNumber)?.doubleValue,
            let y = (raw["y"] as? NSNumber)?.doubleValue,
            let width = (raw["width"] as? NSNumber)?.doubleValue,
            let height = (raw["height"] as? NSNumber)?.doubleValue
        {
            frame = (x, y, width, height)
        }
        return KeyboardState(
            visible: result["visible"] as? Bool ?? false,
            owner: result["owner"] as? String,
            frame: frame,
            detection: result["detection"] as? String ?? "unknown"
        )
    }

    public struct PasteResult: Sendable {
        public let pasted: Bool
        /// `false` when the bridge could not read the focused field to
        /// confirm. Distinguishes "we know it worked" from "we could not
        /// check" — an agent should re-read the screen in the latter case
        /// rather than assume either way.
        public let verified: Bool
        public let clipboardSet: Bool
        public let reason: String?
        public let hint: String?
    }

    public func paste(text: String, replace: Bool, clipboardOnly: Bool) throws -> PasteResult {
        let json = try requestJSON(method: "POST", path: "/paste", form: [
            "base64_text": Data(text.utf8).base64EncodedString(),
            "replace": replace ? "true" : "false",
            "clipboard_only": clipboardOnly ? "true" : "false",
        ])
        let result = json["result"] as? [String: Any]
        return PasteResult(
            pasted: result?["pasted"] as? Bool ?? false,
            verified: result?["verified"] as? Bool ?? false,
            clipboardSet: result?["clipboard"] as? Bool ?? false,
            reason: result?["reason"] as? String,
            hint: result?["hint"] as? String
        )
    }

    /// Runtime report of which XCUIAutomation SPI resolved on the
    /// device. Surfaced by `sim-use ios-device init --verbose` and
    /// worth keeping in the client rather than as a debug script: when
    /// a new Xcode breaks the bridge, this is the first thing to read.
    public func diagnostics() throws -> [String: Any] {
        let json = try requestJSON(method: "GET", path: "/diag")
        return json["result"] as? [String: Any] ?? [:]
    }

    // MARK: - Plumbing

    private func requestJSON(
        method: String,
        path: String,
        form: [String: String]? = nil,
        requiresAuth: Bool = true,
        timeout: TimeInterval = 30
    ) throws -> [String: Any] {
        var body: Data?
        var contentType: String?
        if let form {
            body = Data(Self.formEncode(form).utf8)
            contentType = "application/x-www-form-urlencoded"
        }

        let request = BridgeHTTPRequest(
            method: method,
            path: path,
            body: body,
            contentType: contentType,
            bearerToken: requiresAuth ? token : nil,
            timeout: timeout
        )

        let response: BridgeHTTPResponse
        do {
            response = try transport.send(request)
        } catch {
            throw IOSDeviceBridgeError.transport(
                underlying: error.localizedDescription,
                endpoint: transport.describedEndpoint
            )
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: response.body),
            let json = object as? [String: Any]
        else {
            let preview = String(data: response.body.prefix(200), encoding: .utf8) ?? "<binary>"
            throw IOSDeviceBridgeError.malformedEnvelope("HTTP \(response.status), body: \(preview)")
        }

        if (json["status"] as? String) == "error" || response.status >= 400 {
            throw IOSDeviceBridgeError.applicationError(
                httpStatus: response.status,
                code: json["code"] as? String ?? "unknown",
                message: json["error"] as? String
            )
        }
        return json
    }

    static func formEncode(_ fields: [String: String]) -> String {
        fields
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .sorted()
            .joined(separator: "&")
    }

    /// Percent-encodes for `application/x-www-form-urlencoded`.
    /// `+`, `&`, `=` and `/` must all be escaped — base64 payloads
    /// contain `+` and `/`, and an unescaped `+` decodes to a space on
    /// the far side, silently corrupting every `type` and `paste` whose
    /// text happens to encode one.
    static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

public enum IOSDeviceBridgeError: Error, LocalizedError {
    case transport(underlying: String, endpoint: String)
    case malformedEnvelope(String)
    case applicationError(httpStatus: Int, code: String, message: String?)
    case protocolMismatch(expected: Int, actual: Int, bridgeVersion: String)
    case noSession(udid: String)
    case bridgeNotRunning(udid: String)

    public var errorDescription: String? {
        switch self {
        case .transport(let underlying, let endpoint):
            return "Could not reach the device bridge at \(endpoint): \(underlying)"
        case .malformedEnvelope(let detail):
            return "The device bridge sent an unexpected response: \(detail)"
        case .applicationError(_, let code, let message):
            if let message { return "Device bridge error [\(code)]: \(message)" }
            return "Device bridge error [\(code)]"
        case .protocolMismatch(let expected, let actual, let bridgeVersion):
            return """
                Device bridge protocol mismatch: this sim-use speaks version \(expected), \
                the installed bridge (\(bridgeVersion)) speaks \(actual). \
                Re-run `sim-use ios-device init --rebuild` to rebuild the runner from the bundled sources.
                """
        case .noSession(let udid):
            return "No bridge session for \(udid). Run `sim-use ios-device init --udid \(udid)` first."
        case .bridgeNotRunning(let udid):
            return """
                The bridge session for \(udid) has ended (the xcodebuild process that hosted it is gone). \
                Re-run `sim-use ios-device init --udid \(udid)`.
                """
        }
    }
}
