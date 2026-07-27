// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Everything a later `sim-use` invocation needs to talk to a bridge
/// that is already running on a device.
///
/// The Android backend can rediscover its session cheaply (`adb shell
/// content query` for the token, `adb forward` for the port). Here the
/// token only ever existed in the host's memory and in the launched
/// runner's environment, so if this file is lost the only recovery is
/// to relaunch the runner. That makes the store load-bearing rather
/// than a cache, which is why it is written atomically and 0600.
public struct IOSDeviceBridgeSession: Codable, Equatable, Sendable {
    public let udid: String
    public let token: String
    public let port: UInt16
    /// Every address the runner advertised, in the order it reported
    /// them. Kept in full so a Mac that changes networks can re-probe
    /// without relaunching the runner.
    public let addresses: [String]
    /// The address that last answered `/ping`, when the session is on
    /// the network transport. Nil means "use USB".
    public let preferredHost: String?
    /// PID of the `xcodebuild test-without-building` process holding the
    /// session open. Used to report whether the bridge is still alive
    /// and to stop it.
    public let launcherPID: Int32
    public let xctestrunPath: String
    public let bridgeVersion: String
    public let protocolVersion: Int
    public let startedAt: Date

    public init(
        udid: String,
        token: String,
        port: UInt16,
        addresses: [String],
        preferredHost: String?,
        launcherPID: Int32,
        xctestrunPath: String,
        bridgeVersion: String,
        protocolVersion: Int,
        startedAt: Date = Date()
    ) {
        self.udid = udid
        self.token = token
        self.port = port
        self.addresses = addresses
        self.preferredHost = preferredHost
        self.launcherPID = launcherPID
        self.xctestrunPath = xctestrunPath
        self.bridgeVersion = bridgeVersion
        self.protocolVersion = protocolVersion
        self.startedAt = startedAt
    }

    /// `true` when the process that launched the runner is still around.
    /// A dead launcher means the test session ended and the on-device
    /// bridge went with it, however healthy the file looks.
    public var launcherIsAlive: Bool {
        guard launcherPID > 0 else { return false }
        // kill(pid, 0) probes for existence without signalling. EPERM
        // means the process exists but belongs to someone else, which
        // still counts as alive.
        if kill(launcherPID, 0) == 0 { return true }
        return errno == EPERM
    }
}

public enum IOSDeviceBridgeSessionStore {

    public static func directory(for udid: String, home: URL = homeDirectory) -> URL {
        home
            .appendingPathComponent(".sim-use", isDirectory: true)
            .appendingPathComponent(udid, isDirectory: true)
    }

    public static func file(for udid: String, home: URL = homeDirectory) -> URL {
        directory(for: udid, home: home).appendingPathComponent("ios-bridge.json")
    }

    public static func read(udid: String, home: URL = homeDirectory) -> IOSDeviceBridgeSession? {
        guard isValidUDID(udid) else { return nil }
        guard let data = try? Data(contentsOf: file(for: udid, home: home)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(IOSDeviceBridgeSession.self, from: data)
    }

    public static func write(_ session: IOSDeviceBridgeSession, home: URL = homeDirectory) {
        guard isValidUDID(session.udid) else { return }
        let dir = directory(for: session.udid, home: home)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(session) else { return }
        let url = file(for: session.udid, home: home)
        try? data.write(to: url, options: [.atomic])
        // Holds the bearer token; the default 0644 from the process
        // umask would leave it readable by every user on the machine.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func invalidate(udid: String, home: URL = homeDirectory) {
        guard isValidUDID(udid) else { return }
        try? FileManager.default.removeItem(at: file(for: udid, home: home))
    }

    /// Rejects anything that could escape the `~/.sim-use/` tree. Real
    /// iOS UDIDs are hex and one dash, so this is strict on purpose.
    static func isValidUDID(_ udid: String) -> Bool {
        guard !udid.isEmpty, udid.count <= 64 else { return false }
        guard !udid.contains("/"), udid != ".", udid != ".." else { return false }
        return udid.allSatisfy { ($0.isHexDigit && $0.isASCII) || $0 == "-" }
    }

    public static let homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
}
