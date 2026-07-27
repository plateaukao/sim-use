// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Builds the bridge runner and keeps a test session alive on a device.
///
/// The whole lifecycle exists because of one constraint: on a
/// non-jailbroken iPhone, cross-app accessibility and event injection
/// are granted only to a process `testmanagerd` is supervising, and
/// they are revoked the moment the test method returns. There is no
/// "install and forget" equivalent of the Android APK — something on
/// the host has to hold the session open. That something is a detached
/// `xcodebuild test-without-building` process whose PID we record.
public struct BridgeRunnerLauncher {

    public struct Options: Sendable {
        public var udid: String
        public var teamID: String?
        public var projectPath: String?
        public var port: UInt16
        /// Force a rebuild even when a cached build for this
        /// (project, team, OS major) already exists.
        public var rebuild: Bool
        public var buildTimeout: TimeInterval
        public var readyTimeout: TimeInterval

        public init(
            udid: String,
            teamID: String? = nil,
            projectPath: String? = nil,
            port: UInt16 = 8412,
            rebuild: Bool = false,
            buildTimeout: TimeInterval = 600,
            readyTimeout: TimeInterval = 180
        ) {
            self.udid = udid
            self.teamID = teamID
            self.projectPath = projectPath
            self.port = port
            self.rebuild = rebuild
            self.buildTimeout = buildTimeout
            self.readyTimeout = readyTimeout
        }
    }

    public enum LauncherError: Error, LocalizedError {
        case buildFailed(log: String)
        case noXCTestRun(derivedData: String)
        case launchFailed(String)
        case deviceLocked(udid: String)
        case noTeam
        case readyTimeout(seconds: Int, log: String)
        case runnerReportedFailure(String)

        public var errorDescription: String? {
            switch self {
            case .buildFailed(let log):
                return "Building the iOS bridge runner failed.\n\(Self.tail(log))"
            case .noXCTestRun(let derivedData):
                return "The build produced no .xctestrun file under \(derivedData). This usually means the scheme built for the wrong destination."
            case .launchFailed(let detail):
                return "Could not start the bridge runner: \(detail)"
            case .deviceLocked(let udid):
                return """
                    Device \(udid) is locked. Xcode cannot launch a test runner on a locked device — \
                    unlock the phone (and keep it unlocked, or set Display & Brightness → Auto-Lock to Never \
                    for long sessions), then re-run.
                    """
            case .noTeam:
                return """
                    No development team specified and none could be inferred. The bridge runner has to be \
                    signed by a team your device trusts — there is no prebuilt, universally-installable \
                    runner the way there is an Android APK.

                    Pass --team-id <TEAMID>, or set SIM_USE_IOS_TEAM_ID. Find yours with:
                      security find-identity -v -p codesigning
                    """
            case .readyTimeout(let seconds, let log):
                return "The bridge runner did not report ready within \(seconds)s.\n\(Self.tail(log))"
            case .runnerReportedFailure(let detail):
                return "The bridge runner started but could not serve: \(detail)"
            }
        }

        /// Xcode logs are enormous and the useful part is at the end.
        private static func tail(_ log: String, lines: Int = 25) -> String {
            let all = log.components(separatedBy: .newlines).filter { !$0.isEmpty }
            return all.suffix(lines).joined(separator: "\n")
        }
    }

    public init() {}

    // MARK: - Build

    /// Where built runners live between sessions.
    ///
    /// Keyed by every input that changes the product: project location,
    /// signing team, Xcode version, **and a fingerprint of the bridge
    /// sources**. The source fingerprint is not optional — without it,
    /// editing a handler and re-running `init` reuses the previous build
    /// and relaunches the old runner, so the fix appears not to work and
    /// there is nothing in the output to suggest why.
    public static func buildDirectory(
        projectPath: URL,
        teamID: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let key = "\(projectPath.path)|\(teamID)|\(xcodeBuildVersion())|\(sourceFingerprint(projectPath))"
        return home
            .appendingPathComponent(".sim-use", isDirectory: true)
            .appendingPathComponent("ios-bridge", isDirectory: true)
            .appendingPathComponent(shortHash(key), isDirectory: true)
    }

    /// Content hash of everything that affects the built runner: the
    /// sources, the bridging header, the Info.plist, and the project
    /// file itself.
    ///
    /// Content rather than mtime because the release path stages the
    /// tree with `rsync -a` into a resource bundle, and an unpacked
    /// tarball's timestamps say nothing useful. The tree is ~20 small
    /// files, so reading all of them costs a couple of milliseconds —
    /// far less than the wrong-build debugging session it prevents.
    static func sourceFingerprint(_ projectPath: URL) -> String {
        let interesting: Set<String> = ["swift", "h", "m", "plist", "pbxproj"]
        guard let enumerator = FileManager.default.enumerator(
            at: projectPath,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "unfingerprinted"
        }

        var entries: [String] = []
        for case let url as URL in enumerator where interesting.contains(url.pathExtension) {
            guard let data = try? Data(contentsOf: url) else { continue }
            let relative = url.path.replacingOccurrences(of: projectPath.path, with: "")
            entries.append("\(relative):\(shortHash(String(decoding: data, as: UTF8.self)))")
        }
        // Directory enumeration order is not guaranteed stable across
        // filesystems; sort so the same tree always hashes the same.
        return shortHash(entries.sorted().joined(separator: "|"))
    }

    /// FNV-1a. A cryptographic digest would mean importing CryptoKit
    /// for a cache-directory name; collisions here cost a rebuild, not
    /// correctness.
    static func shortHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return String(hash, radix: 36)
    }

    static func xcodeBuildVersion() -> String {
        (try? Shell.run("/usr/bin/xcrun", ["xcodebuild", "-version"]).stdout)?
            .components(separatedBy: .newlines).first ?? "unknown"
    }

    public struct BuildResult: Sendable {
        public let xctestrunPath: URL
        public let reusedCache: Bool
    }

    /// Runs `xcodebuild build-for-testing`, producing the runner app and
    /// the `.xctestrun` that describes how to launch it.
    public func build(options: Options, log: (String) -> Void = { _ in }) throws -> BuildResult {
        let projectDirectory = try BridgeRunnerProject.locate(explicit: options.projectPath)
        let teamID = try resolveTeamID(options.teamID)
        let derivedData = Self.buildDirectory(projectPath: projectDirectory, teamID: teamID)

        if !options.rebuild, let cached = Self.findXCTestRun(in: derivedData) {
            log("Reusing cached bridge runner at \(cached.path)")
            return BuildResult(xctestrunPath: cached, reusedCache: true)
        }

        log("Building the bridge runner (this takes a minute on a cold cache)…")
        let result = try Shell.run(
            "/usr/bin/xcrun",
            [
                "xcodebuild", "build-for-testing",
                "-project", projectDirectory.appendingPathComponent(BridgeRunnerProject.projectFileName).path,
                "-scheme", BridgeRunnerProject.schemeName,
                "-destination", "id=\(options.udid)",
                "-derivedDataPath", derivedData.path,
                "-allowProvisioningUpdates",
                "DEVELOPMENT_TEAM=\(teamID)",
            ],
            timeout: options.buildTimeout
        )
        guard result.exitCode == 0 else {
            throw LauncherError.buildFailed(log: result.stdout + "\n" + result.stderr)
        }
        guard let xctestrun = Self.findXCTestRun(in: derivedData) else {
            throw LauncherError.noXCTestRun(derivedData: derivedData.path)
        }
        return BuildResult(xctestrunPath: xctestrun, reusedCache: false)
    }

    static func findXCTestRun(in derivedData: URL) -> URL? {
        let products = derivedData.appendingPathComponent("Build/Products", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: products,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        // Newest wins: a device on a newer iOS leaves the older
        // platform's xctestrun behind, and launching that one fails with
        // an unhelpful "no such destination".
        return entries
            .filter { $0.pathExtension == "xctestrun" }
            .max { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate < rhsDate
            }
    }

    /// Signing team, in order: explicit flag, environment, then the
    /// single Apple Development identity in the keychain if there is
    /// exactly one. Guessing between several would produce a build that
    /// fails much later with a confusing provisioning error, so we stop
    /// and ask instead.
    func resolveTeamID(_ explicit: String?) throws -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        if let fromEnvironment = ProcessInfo.processInfo.environment["SIM_USE_IOS_TEAM_ID"], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        let identities = Self.developmentTeamIDs()
        guard identities.count == 1, let only = identities.first else {
            throw LauncherError.noTeam
        }
        return only
    }

    /// Team IDs from `Apple Development` codesigning identities. The
    /// team is the parenthesised suffix of the identity's common name.
    static func developmentTeamIDs() -> [String] {
        guard let output = try? Shell.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]).stdout else {
            return []
        }
        var found: [String] = []
        for line in output.components(separatedBy: .newlines) where line.contains("Apple Development") {
            guard let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { continue }
            let team = String(line[line.index(after: open)..<close])
            if !team.isEmpty && !found.contains(team) { found.append(team) }
        }
        return found
    }

    // MARK: - Launch

    public struct LaunchResult: Sendable {
        public let session: IOSDeviceBridgeSession
        public let logPath: URL
    }

    /// Patches the `.xctestrun` with our token and port, then starts a
    /// detached `test-without-building` and waits for the runner's ready
    /// line.
    public func launch(
        options: Options,
        xctestrunPath: URL,
        log: (String) -> Void = { _ in }
    ) throws -> LaunchResult {
        let token = UUID().uuidString
        try Self.patchXCTestRun(at: xctestrunPath, token: token, port: options.port)

        let logURL = IOSDeviceBridgeSessionStore
            .directory(for: options.udid)
            .appendingPathComponent("ios-bridge.log")
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: logURL.path) else {
            throw LauncherError.launchFailed("cannot open \(logURL.path) for writing")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcodebuild", "test-without-building",
            "-xctestrun", xctestrunPath.path,
            "-destination", "id=\(options.udid)",
        ]
        process.standardOutput = handle
        process.standardError = handle
        // Detach from the CLI's process group so the session outlives
        // this invocation — the entire point of the launcher.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw LauncherError.launchFailed(error.localizedDescription)
        }

        log("Launched bridge runner (pid \(process.processIdentifier)); waiting for it to come up…")
        let ready = try waitForReady(
            logURL: logURL,
            process: process,
            timeout: options.readyTimeout,
            udid: options.udid
        )

        let preferredHost = USBMuxTransport.attachedUDIDs().contains(USBMuxTransport.normalizeUDID(options.udid))
            ? nil
            : NetworkTransport.firstReachable(addresses: ready.addresses, port: ready.port)

        let session = IOSDeviceBridgeSession(
            udid: options.udid,
            token: token,
            port: ready.port,
            addresses: ready.addresses,
            preferredHost: preferredHost,
            launcherPID: process.processIdentifier,
            xctestrunPath: xctestrunPath.path,
            bridgeVersion: ready.bridgeVersion,
            protocolVersion: ready.protocolVersion,
            startedAt: Date()
        )
        IOSDeviceBridgeSessionStore.write(session)
        return LaunchResult(session: session, logPath: logURL)
    }

    /// Injects the bearer token and port into the runner's environment.
    ///
    /// Inverted from the Android bridge, where the app mints the token
    /// and `adb shell content query` fetches it. A test runner has no
    /// equivalent inbound channel, so the host generates the secret and
    /// hands it over at launch — which also means the token never has
    /// to be persisted on the phone.
    ///
    /// The file is patched **in place**: `__TESTROOT__` inside a
    /// `.xctestrun` resolves relative to the file's own directory, so a
    /// copy elsewhere points at products that are not there.
    static func patchXCTestRun(at url: URL, token: String, port: UInt16) throws {
        guard
            let data = try? Data(contentsOf: url),
            var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            throw LauncherError.launchFailed("cannot read \(url.lastPathComponent)")
        }

        for (key, value) in plist {
            guard key != "__xctestrun_metadata__", var target = value as? [String: Any] else { continue }
            var environment = target["EnvironmentVariables"] as? [String: Any] ?? [:]
            environment["SIMUSE_BRIDGE_TOKEN"] = token
            environment["SIMUSE_BRIDGE_PORT"] = String(port)
            target["EnvironmentVariables"] = environment
            plist[key] = target
        }

        guard let out = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            throw LauncherError.launchFailed("cannot re-encode \(url.lastPathComponent)")
        }
        try out.write(to: url, options: [.atomic])
    }

    struct ReadyPayload {
        let port: UInt16
        let addresses: [String]
        let protocolVersion: Int
        let bridgeVersion: String
    }

    private func waitForReady(
        logURL: URL,
        process: Process,
        timeout: TimeInterval,
        udid: String
    ) throws -> ReadyPayload {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""

            if let payload = Self.parseMarker(log, marker: "SIMUSE_BRIDGE_READY") {
                return try Self.decodeReady(payload)
            }
            if let payload = Self.parseMarker(log, marker: "SIMUSE_BRIDGE_FAILED") {
                process.terminate()
                throw LauncherError.runnerReportedFailure(payload)
            }
            // Xcode refuses to launch a test on a locked device, and
            // sits in a retry loop rather than failing — so detecting it
            // here is the difference between a clear message and a
            // three-minute timeout.
            if log.contains("to Continue") && log.contains("locked") {
                process.terminate()
                throw LauncherError.deviceLocked(udid: udid)
            }
            if !process.isRunning {
                throw LauncherError.launchFailed(
                    "xcodebuild exited with status \(process.terminationStatus) before the bridge came up. See \(logURL.path)"
                )
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        process.terminate()
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        throw LauncherError.readyTimeout(seconds: Int(timeout), log: log)
    }

    /// Extracts `MARKER->{json}<-MARKER`. Delimited on both sides
    /// because xcodebuild interleaves its own logging with test stdout
    /// and a bare prefix match picks up half a line.
    static func parseMarker(_ log: String, marker: String) -> String? {
        let opening = "\(marker)->"
        let closing = "<-\(marker)"
        guard
            let start = log.range(of: opening),
            let end = log.range(of: closing, range: start.upperBound..<log.endIndex)
        else { return nil }
        return String(log[start.upperBound..<end.lowerBound])
    }

    static func decodeReady(_ payload: String) throws -> ReadyPayload {
        guard
            let data = payload.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw LauncherError.runnerReportedFailure("unparseable ready payload: \(payload)")
        }
        let port = (json["port"] as? NSNumber)?.uint16Value ?? 8412
        return ReadyPayload(
            port: port,
            addresses: json["addresses"] as? [String] ?? [],
            protocolVersion: (json["protocol_version"] as? NSNumber)?.intValue ?? -1,
            bridgeVersion: json["bridge_version"] as? String ?? "unknown"
        )
    }

    // MARK: - Stop

    /// Ends a session by terminating the launcher. The on-device runner
    /// goes down with it — the test process is a child of the session
    /// `testmanagerd` is brokering, so there is nothing left to clean up
    /// on the phone.
    @discardableResult
    public static func stop(udid: String) -> Bool {
        guard let session = IOSDeviceBridgeSessionStore.read(udid: udid) else { return false }
        defer { IOSDeviceBridgeSessionStore.invalidate(udid: udid) }
        guard session.launcherIsAlive else { return false }
        return kill(session.launcherPID, SIGTERM) == 0
    }
}
