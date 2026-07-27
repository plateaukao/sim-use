// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use ios-device init` — build the bridge runner, launch it on the
/// device, and verify it answers.
public struct IOSDeviceInitCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Build and start the on-device bridge for a real iPhone / iPad.",
        discussion: """
        Builds `ios-bridge/` with your signing team, launches it as an XCUITest
        session, and records the connection in ~/.sim-use/<udid>/ios-bridge.json.

        The first run takes a minute or two (a cold Xcode build); later runs
        reuse the cached build unless you pass --rebuild or change team / Xcode.

        The device must be **unlocked** — iOS refuses to launch a test runner on
        a locked device. For long sessions, set Auto-Lock to Never.
        """
    )

    @OptionGroup public var device: IOSDeviceOptions

    @Option(name: .customLong("team-id"), help: "Apple Development team ID used to sign the runner. Defaults to SIM_USE_IOS_TEAM_ID, or the only Apple Development identity in your keychain.")
    public var teamID: String?

    @Option(name: .customLong("project-path"), help: "Override the ios-bridge project location (advanced).")
    public var projectPath: String?

    @Option(name: .customLong("port"), help: "Port the bridge listens on inside the device (default 8412).")
    public var port: UInt16 = 8412

    @Flag(name: .customLong("rebuild"), help: "Force a rebuild of the runner even if a cached build exists.")
    public var rebuild: Bool = false

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {...}}` envelope.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public let deviceId: String
        public let deviceName: String
        public let bridgeVersion: String
        public let protocolVersion: Int
        public let endpoint: String
        public let transport: String
        public let reusedBuild: Bool
        public let logPath: String
        public let diagnostics: [String: String]
    }

    /// Bootstraps the session the daemon would itself depend on, so it
    /// must never be routed through one.
    public var daemonBypass: Bool { true }
    public var simulatorUDIDForDaemon: String? { device.resolved }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        let controller = IOSDeviceController()
        let options = BridgeRunnerLauncher.Options(
            udid: device.resolved,
            teamID: teamID,
            projectPath: projectPath,
            port: port,
            rebuild: rebuild
        )
        // Progress goes to stderr so `--json` stdout stays a clean
        // envelope; a two-minute silent build otherwise reads as a hang.
        let report = try controller.initialize(options: options) { message in
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        }
        return ExecutionResult(
            deviceId: report.udid,
            deviceName: report.deviceName,
            bridgeVersion: report.bridgeVersion,
            protocolVersion: report.protocolVersion,
            endpoint: report.endpoint,
            transport: report.transport,
            reusedBuild: report.reusedBuild,
            logPath: report.logPath,
            diagnostics: report.diagnostics
        )
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        var lines = [
            "Bridge running on \(result.deviceName) (\(result.deviceId))",
            "  bridge_version    \(result.bridgeVersion)",
            "  protocol_version  \(result.protocolVersion)",
            "  transport         \(result.transport)",
            "  endpoint          \(result.endpoint)",
            "  build             \(result.reusedBuild ? "reused cache" : "fresh")",
            "  log               \(result.logPath)",
        ]
        // A runner whose private-API probes failed still serves
        // screenshots, so it looks healthy until the first tap. Say so
        // up front instead.
        if result.diagnostics["spi_available"] == "false" {
            lines.append("")
            lines.append("  warning: the XCUIAutomation SPI this Xcode ships did not resolve.")
            lines.append("  \(result.diagnostics["spi_unavailable_reason"] ?? "")")
            lines.append("  Gestures and typing will fail; screenshots and describe-ui may still work.")
        }
        return .lines(lines)
    }
}

/// `sim-use ios-device stop` — end the session.
public struct IOSDeviceStopCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the on-device bridge session for a device."
    )

    @OptionGroup public var device: IOSDeviceOptions

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {stopped}}` envelope.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public let deviceId: String
        public let stopped: Bool
    }

    public var daemonBypass: Bool { true }
    public var simulatorUDIDForDaemon: String? { device.resolved }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        ExecutionResult(
            deviceId: device.resolved,
            stopped: BridgeRunnerLauncher.stop(udid: device.resolved)
        )
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line(result.stopped
            ? "Stopped the bridge session on \(result.deviceId)."
            : "No running bridge session for \(result.deviceId).")
    }
}

/// `sim-use ios-device status` — is a session up, and is it answering?
public struct IOSDeviceStatusCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report whether a bridge session is running and reachable."
    )

    @OptionGroup public var device: IOSDeviceOptions

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {...}}` envelope.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public let deviceId: String
        public let hasSession: Bool
        public let launcherAlive: Bool
        public let reachable: Bool
        public let endpoint: String?
        public let bridgeVersion: String?
        public let startedAt: Date?
    }

    public var daemonBypass: Bool { true }
    public var simulatorUDIDForDaemon: String? { device.resolved }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        guard let session = IOSDeviceBridgeSessionStore.read(udid: device.resolved) else {
            return ExecutionResult(
                deviceId: device.resolved,
                hasSession: false,
                launcherAlive: false,
                reachable: false,
                endpoint: nil,
                bridgeVersion: nil,
                startedAt: nil
            )
        }
        let alive = session.launcherIsAlive
        var reachable = false
        var endpoint: String?
        var bridgeVersion: String?
        if alive, let client = try? IOSDeviceBridgeClient.fromSession(session) {
            endpoint = client.describedEndpoint
            if let ping = try? client.ping(force: true) {
                reachable = true
                bridgeVersion = ping.bridgeVersion
            }
        }
        return ExecutionResult(
            deviceId: session.udid,
            hasSession: true,
            launcherAlive: alive,
            reachable: reachable,
            endpoint: endpoint,
            bridgeVersion: bridgeVersion ?? session.bridgeVersion,
            startedAt: session.startedAt
        )
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        guard result.hasSession else {
            return .line("No bridge session for \(result.deviceId). Run `sim-use ios-device init`.")
        }
        if !result.launcherAlive {
            return .line("Bridge session for \(result.deviceId) has ended (launcher process is gone). Run `sim-use ios-device init`.")
        }
        return .lines([
            "Bridge session on \(result.deviceId)",
            "  reachable         \(result.reachable ? "yes" : "no")",
            "  endpoint          \(result.endpoint ?? "unknown")",
            "  bridge_version    \(result.bridgeVersion ?? "unknown")",
            "  started           \(result.startedAt.map(ISO8601DateFormatter().string(from:)) ?? "unknown")",
        ])
    }
}

/// `sim-use ios-device devices` — what `devicectl` can see.
public struct IOSDeviceDevicesCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List paired real iOS devices."
    )

    @Flag(name: .customLong("all"), help: "Include devices that aren't currently usable.")
    public var includeAll: Bool = false

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {devices: [...]}}` envelope.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public let devices: [Device]
    }

    public var daemonBypass: Bool { true }

    public func execute() async throws -> ExecutionResult {
        ExecutionResult(devices: try DeviceCtl().listUnifiedDevices(onlineOnly: !includeAll))
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        guard !result.devices.isEmpty else {
            return .line("No real iOS devices found. Pass --all to include unavailable ones.")
        }
        let rows = result.devices.map { device in
            "  \(device.udid)  \(device.name)  [\(device.state)]  \(device.runtime ?? "")"
        }
        return .lines(["Real iOS devices:"] + rows)
    }
}
