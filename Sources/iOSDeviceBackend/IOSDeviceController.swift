// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore
import iOSSimBackend

/// High-level operations for real iOS devices. The counterpart of
/// `AndroidDeviceController`: resolves a live bridge session, runs the
/// describe-ui pipeline, and owns the `ios-device init` bootstrap.
public final class IOSDeviceController {

    public let deviceCtl: DeviceCtl

    public init(deviceCtl: DeviceCtl = DeviceCtl()) {
        self.deviceCtl = deviceCtl
    }

    // MARK: - Session

    /// Returns a client for a device with a live bridge, or an error
    /// explaining which precondition failed.
    ///
    /// Liveness is checked against the launcher process rather than by
    /// pinging first: a stale session file whose `xcodebuild` died is
    /// the common failure, and "run init again" is a far more useful
    /// message than a connection timeout thirty seconds later.
    public func client(udid: String) throws -> IOSDeviceBridgeClient {
        guard let session = IOSDeviceBridgeSessionStore.read(udid: udid) else {
            throw IOSDeviceBridgeError.noSession(udid: udid)
        }
        guard session.launcherIsAlive else {
            throw IOSDeviceBridgeError.bridgeNotRunning(udid: udid)
        }
        return try IOSDeviceBridgeClient.fromSession(session)
    }

    // MARK: - describe-ui

    /// Fetch → decode → render → cache, mirroring
    /// `AndroidDeviceController.describeUI` and the Simulator's
    /// `describe-ui` so all three produce the same outline contract.
    public func describeUI(
        udid: String,
        filter: Bool = false,
        bundleID: String? = nil,
        includeRaw: Bool = true
    ) throws -> DescribeUIResult {
        let client = try self.client(udid: udid)
        try client.ping()

        let tree = try client.fetchTree(filter: filter, bundleID: bundleID)
        let elements = try JSONDecoder().decode([AccessibilityElement].self, from: tree.elementsJSON)

        // The bridge already knows the foreground bundle id first-hand,
        // so `ForegroundLabel` gets an authoritative answer here. On the
        // Simulator this has to be recovered from the AX root's pid via
        // launchctl, which is why that path can disagree with reality
        // (issue #81) and this one cannot.
        let outline = OutlineFormatter.render(
            tree: elements,
            foregroundBundleId: tree.appBundleID
        )

        let rawJSON: JSONValue? = includeRaw ? try JSONValue.decode(from: tree.elementsJSON) : nil

        do {
            try OutlineCache.write(outline: outline, udid: udid)
        } catch {
            FileHandle.standardError.write(Data(
                "warning: failed to write outline cache for \(udid): \(error.localizedDescription)\n".utf8
            ))
        }

        return DescribeUIResult(
            platform: .iosDevice,
            raw: rawJSON,
            outline: outline.text,
            entries: outline.entries,
            lists: outline.lists,
            screen: outline.screen,
            appLabel: outline.appLabel,
            appPackage: tree.appBundleID ?? ""
        )
    }

    // MARK: - init / bootstrap

    public struct InitReport: Sendable {
        public let udid: String
        public let deviceName: String
        public let bridgeVersion: String
        public let protocolVersion: Int
        public let endpoint: String
        public let transport: String
        public let reusedBuild: Bool
        public let logPath: String
        /// Runtime SPI report from the runner. Empty when `/diag` could
        /// not be reached.
        public let diagnostics: [String: String]
    }

    /// Builds the runner (or reuses a cached build), launches a test
    /// session, and verifies it answers.
    ///
    /// Idempotent in the sense that matters: re-running replaces any
    /// previous session for the device rather than stacking a second
    /// runner on the same port.
    public func initialize(
        options: BridgeRunnerLauncher.Options,
        log: (String) -> Void = { _ in }
    ) throws -> InitReport {
        let devices = (try? deviceCtl.devices()) ?? []
        guard let device = devices.first(where: { $0.udid == options.udid }) else {
            throw InitError.unknownDevice(udid: options.udid, known: devices.map { "\($0.udid) (\($0.name))" })
        }
        guard device.developerModeEnabled else {
            throw InitError.developerModeDisabled(name: device.name)
        }

        let launcher = BridgeRunnerLauncher()

        // Build BEFORE tearing down any existing session. A rebuild can
        // take minutes, and while a session is live the runner holds the
        // device's idle timer — kill it first and the phone auto-locks
        // during the build, after which iOS refuses to launch the new
        // runner and the user is told to go unlock their phone. Ordering
        // the two steps this way keeps the device awake across its own
        // replacement.
        let build = try launcher.build(options: options, log: log)

        // Now swap. Two runners racing for the same port would make the
        // second fail to bind, so the old one has to go before the new
        // one starts.
        if let existing = IOSDeviceBridgeSessionStore.read(udid: options.udid), existing.launcherIsAlive {
            log("Stopping the previous bridge session (pid \(existing.launcherPID))…")
            BridgeRunnerLauncher.stop(udid: options.udid)
            // Give the port a moment to come free before rebinding.
            Thread.sleep(forTimeInterval: 1.0)
        }

        let launch = try launcher.launch(options: options, xctestrunPath: build.xctestrunPath, log: log)

        let client = try IOSDeviceBridgeClient.fromSession(launch.session)
        let ping = try client.ping(force: true)

        var diagnostics: [String: String] = [:]
        for (key, value) in (try? client.diagnostics()) ?? [:] {
            diagnostics[key] = String(describing: value)
        }

        return InitReport(
            udid: options.udid,
            deviceName: device.name,
            bridgeVersion: ping.bridgeVersion,
            protocolVersion: ping.protocolVersion,
            endpoint: client.describedEndpoint,
            transport: launch.session.preferredHost == nil ? "usb" : "network",
            reusedBuild: build.reusedCache,
            logPath: launch.logPath.path,
            diagnostics: diagnostics
        )
    }

    public enum InitError: Error, LocalizedError {
        case unknownDevice(udid: String, known: [String])
        case developerModeDisabled(name: String)

        public var errorDescription: String? {
            switch self {
            case .unknownDevice(let udid, let known):
                let list = known.isEmpty ? "none paired" : known.joined(separator: "\n  ")
                return """
                    `devicectl` does not know device \(udid). Paired devices:
                      \(list)
                    Connect the device over USB (or Wi-Fi with "Connect via network" enabled in Xcode) and trust this Mac.
                    """
            case .developerModeDisabled(let name):
                return """
                    Developer Mode is off on \(name). Enable it on the device under \
                    Settings → Privacy & Security → Developer Mode, then reboot when prompted. \
                    Without it, iOS refuses to launch the test runner the bridge needs.
                    """
            }
        }
    }
}
