// SPDX-License-Identifier: Apache-2.0
import Foundation
import UIKit
import XCTest

/// The bridge's entry point.
///
/// An XCUITest that never returns is the only way to hold cross-app
/// accessibility and event-injection privileges on a non-jailbroken
/// iPhone: those are granted to a process `testmanagerd` is supervising,
/// and they end when the test does. So `testRunBridge` starts an HTTP
/// server and then parks on the work queue forever. `xcodebuild
/// test-without-building` on the host stays attached for the life of the
/// session and tears the runner down when it is killed.
///
/// This is the same shape WebDriverAgent uses, and it is why the iOS
/// bridge cannot be a normal app the way the Android one is.
final class BridgeTestCase: XCTestCase {

    /// A day. XCTest will otherwise abort a long-running test at its
    /// default allowance, which would drop the bridge mid-session for no
    /// reason the user could act on.
    private static let sessionAllowance: TimeInterval = 24 * 60 * 60

    override func setUp() {
        super.setUp()
        // A failed assertion anywhere must not end the session — the
        // whole point is to stay up.
        continueAfterFailure = true
        executionTimeAllowance = Self.sessionAllowance
        disableAutoLock()
    }

    /// Asks iOS not to auto-lock. **This does not actually hold the
    /// device awake, and callers must not rely on it.**
    ///
    /// `isIdleTimerDisabled` is an app-level property that the system
    /// honours only while that app is foreground. The runner is
    /// backgrounded as soon as the app under test comes up, so in
    /// practice the phone still locks during any quiet stretch —
    /// measured: a session with this call in place locked during a
    /// two-minute rebuild. It is left in because it costs nothing and
    /// does help for the window where the runner itself is frontmost.
    ///
    /// The real mitigations live elsewhere:
    ///   - `IOSDeviceController.initialize` builds a replacement runner
    ///     *before* stopping the running one, so a rebuild is covered by
    ///     the live session rather than by a locked screen.
    ///   - Synthesized touches reset the idle timer, so an actively
    ///     driven device stays awake on its own.
    ///   - For long unattended sessions there is no software answer:
    ///     set Auto-Lock to Never, which is what Appium and every device
    ///     farm require too.
    private func disableAutoLock() {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    func testRunBridge() throws {
        let config = BridgeConfig.fromEnvironment()
        let queue = SerialWorkQueue()
        let router = ActionRouter(config: config, queue: queue)
        let server = HTTPServer(port: config.port) { request in
            router.route(request)
        }

        do {
            try server.start()
        } catch {
            // Surface the reason on the same channel the host watches,
            // so a port collision reads as a port collision instead of a
            // silent "the bridge never became ready" timeout.
            Self.emit(marker: Self.failedMarker, payload: ["error": "\(error)"])
            throw error
        }

        Self.emit(marker: Self.readyMarker, payload: [
            "port": Int(config.port),
            "addresses": HostAddresses.local(),
            "protocol_version": BridgeVersion.protocolVersion,
            "bridge_version": BridgeVersion.version,
            // Development convenience: when the host did not inject a
            // token we minted one, and the operator needs to see it.
            // Never printed for a host-driven session.
            "token": config.tokenWasGenerated ? config.token : nil,
            "spi_available": SimUsePrivateAPI.isAvailable,
        ].compactMapValues { $0 })

        // Parks here for the session. Every HTTP request runs its
        // handler on this thread; see `SerialWorkQueue`.
        queue.drainForever()
    }

    // MARK: - Host handshake

    /// Delimited on both sides so the host can recover the payload from
    /// a line that xcodebuild has interleaved with its own logging —
    /// test stdout is not line-atomic once several subsystems are
    /// writing to it.
    static let readyMarker = "SIMUSE_BRIDGE_READY"
    static let failedMarker = "SIMUSE_BRIDGE_FAILED"

    private static func emit(marker: String, payload: [String: Any]) {
        let json: String
        if
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        {
            json = text
        } else {
            json = "{}"
        }
        print("\(marker)->\(json)<-\(marker)")
        // The test runner's stdout is block-buffered when it is not a
        // TTY, which it never is under xcodebuild. Without this the
        // handshake can sit in the buffer for minutes and the host times
        // out waiting for a bridge that is already serving.
        fflush(stdout)
    }
}
