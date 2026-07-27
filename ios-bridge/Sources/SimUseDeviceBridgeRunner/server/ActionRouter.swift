// SPDX-License-Identifier: Apache-2.0
import Foundation

/// `(method, path)` dispatch + bearer auth, mirroring the Android
/// bridge's `ActionRouter.kt` endpoint-for-endpoint. The one shape
/// difference is `/a11y_tree_full`, which returns an **iOS**
/// accessibility tree (see `AXNode`) rather than an Android one.
///
/// Every handler body runs on the XCTest test thread via
/// `SerialWorkQueue`; this type only decides *what* to run and turns
/// the outcome into an envelope.
final class ActionRouter {
    private let config: BridgeConfig
    private let queue: SerialWorkQueue

    private let snapshotHandler = SnapshotHandler()
    private let captureHandler = CaptureHandler()
    private let gestureHandler = GestureHandler()
    private let inputHandler = InputHandler()
    private let keyboardStateHandler = KeyboardStateHandler()
    private let pasteHandler = PasteHandler()

    /// Ceiling on a single handler's time on the test thread. Chosen
    /// above the slowest realistic operation (a full-tree snapshot on a
    /// dense SwiftUI screen measures ~2–4 s on device) and below the
    /// host client's read timeout, so a wedged handler surfaces as a
    /// structured 504 rather than the CLI's generic transport error.
    private static let handlerTimeout: TimeInterval = 30

    /// Screenshots on a ProMotion device can take a beat longer than a
    /// tree walk when the compositor is busy; give them their own,
    /// larger budget instead of raising the ceiling for everything.
    private static let captureTimeout: TimeInterval = 45

    init(config: BridgeConfig, queue: SerialWorkQueue) {
        self.config = config
        self.queue = queue
    }

    func route(_ request: HTTPRequest) -> HTTPResponse {
        // `/ping` is deliberately unauthenticated: the host uses it to
        // discover whether a runner is alive *before* it knows whether
        // its cached token is still valid. It leaks only version
        // numbers. Same carve-out as the Android bridge.
        if request.path != "/ping" && !isAuthorized(request.headers) {
            return HTTPResponse(status: 401, json: Envelope.error(code: "unauthorized"))
        }
        return dispatch(request)
    }

    private func dispatch(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/ping"):
            return ping()
        case ("GET", "/diag"):
            return diagnostics()
        case ("GET", "/a11y_tree_full"):
            return onQueue { self.snapshotHandler.tree(params: request.params) }
        case ("GET", "/screenshot"):
            return onQueue(timeout: Self.captureTimeout) { self.captureHandler.screenshot(params: request.params) }
        case ("GET", "/keyboard/state"):
            return onQueue { self.keyboardStateHandler.state() }
        case ("POST", "/tap"):
            return onQueue { self.gestureHandler.tap(params: request.params) }
        case ("POST", "/swipe"):
            return onQueue { self.gestureHandler.swipe(params: request.params) }
        case ("POST", "/gesture"):
            return onQueue { self.gestureHandler.gesture(params: request.params) }
        case ("POST", "/keyboard/input"):
            return onQueue { self.inputHandler.input(params: request.params) }
        case ("POST", "/keyboard/key"):
            return onQueue { self.inputHandler.key(params: request.params) }
        case ("POST", "/button"):
            return onQueue { self.inputHandler.button(params: request.params) }
        case ("POST", "/paste"):
            return onQueue { self.pasteHandler.paste(params: request.params) }
        default:
            return HTTPResponse(status: 404, json: Envelope.error(code: "unknown_endpoint"))
        }
    }

    private func ping() -> HTTPResponse {
        // Flat envelope — `protocol_version` / `bridge_version` sit
        // beside `status`, not nested under `result`. The host's
        // `PingResult` decodes this exact shape.
        HTTPResponse(status: 200, json: Envelope.success(
            "pong",
            extra: [
                "protocol_version": BridgeVersion.protocolVersion,
                "bridge_version": BridgeVersion.version,
                "platform": "ios",
            ]
        ))
    }

    /// Reports what the version-sensitive SPI actually resolved to on
    /// this device + Xcode pair. Worth an endpoint rather than a log
    /// line: when a new Xcode reshapes `activeForegroundApplications`,
    /// this is the difference between a five-second diagnosis and a
    /// rebuild-and-guess loop.
    private func diagnostics() -> HTTPResponse {
        onQueue {
            HTTPResponse(status: 200, json: Envelope.success([
                "spi_available": SimUsePrivateAPI.isAvailable,
                "spi_unavailable_reason": SimUsePrivateAPI.unavailableReason ?? "",
                "foreground": SimUsePrivateAPI.foregroundDiagnostics(),
                "foreground_bundle_ids": SimUsePrivateAPI.activeForegroundBundleIDs(),
            ]))
        }
    }

    /// Runs `work` on the test thread, converting the two failure modes
    /// the queue can report (stopped, timed out) into wire errors.
    private func onQueue(
        timeout: TimeInterval = ActionRouter.handlerTimeout,
        _ work: @escaping () -> HTTPResponse
    ) -> HTTPResponse {
        let guarded: () -> HTTPResponse = {
            var response: HTTPResponse?
            do {
                // Swift cannot catch NSException, and XCTest raises them
                // from deep inside `snapshot()` and the event system. An
                // uncaught one ends the test method, which ends the
                // session — so every handler runs inside the trap.
                try SimUseExceptionTrap.run { response = work() }
            } catch {
                return HTTPResponse(status: 500, json: Envelope.error(
                    code: "handler_exception",
                    message: error.localizedDescription
                ))
            }
            return response ?? HTTPResponse(status: 500, json: Envelope.error(code: "handler_produced_no_response"))
        }

        guard let response = queue.submit(timeout: timeout, guarded) else {
            return HTTPResponse(status: 504, json: Envelope.error(
                code: "handler_timeout",
                message: "The bridge did not finish within \(Int(timeout))s. A system alert or a wedged app can block automation; dismiss it and retry."
            ))
        }
        return response
    }

    private func isAuthorized(_ headers: [String: String]) -> Bool {
        guard let header = headers["authorization"], header.hasPrefix("Bearer ") else { return false }
        let presented = String(header.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
        return constantTimeEquals(presented, config.token)
    }

    /// Constant-time compare so response latency cannot be used to
    /// recover the token byte by byte. The realistic attacker here is
    /// another process on the same LAN reaching the Wi-Fi transport, so
    /// unlike the Android bridge (loopback-only) this is load-bearing
    /// rather than defence-in-depth.
    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in a.indices { diff |= a[index] ^ b[index] }
        return diff == 0
    }
}
