// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import iOSDeviceBackend

/// Wire-level plumbing for the real-device bridge: HTTP framing, form
/// encoding, the ready-line handshake, and the xctestrun patch. All of
/// it runs without a device.
final class BridgeWireTests: XCTestCase {

    // MARK: - Response parsing

    func testParsesCompleteResponse() throws {
        let body = #"{"status":"success"}"#
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
        let response = try XCTUnwrap(BridgeHTTPResponseParser.parse(raw))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), body)
    }

    /// A partial read must report "keep going", not a truncated body —
    /// otherwise a large tree that arrives in several TCP segments
    /// decodes as malformed JSON.
    func testIncompleteBodyReturnsNil() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 40\r\n\r\n{\"status\":".utf8)
        XCTAssertNil(try BridgeHTTPResponseParser.parse(raw))
    }

    func testHeadersNotYetCompleteReturnsNil() throws {
        XCTAssertNil(try BridgeHTTPResponseParser.parse(Data("HTTP/1.1 200 OK\r\nContent-Len".utf8)))
    }

    func testResponseWithoutContentLengthReadsToEOF() throws {
        let raw = Data("HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\n\r\nboom".utf8)
        XCTAssertTrue(BridgeHTTPResponseParser.needsReadToEOF(raw))
        let response = try XCTUnwrap(BridgeHTTPResponseParser.parse(raw))
        XCTAssertEqual(response.status, 500)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "boom")
    }

    func testMalformedStatusLineThrows() {
        let raw = Data("NOT-HTTP\r\n\r\n".utf8)
        XCTAssertThrowsError(try BridgeHTTPResponseParser.parse(raw))
    }

    /// Body bytes beyond Content-Length (a pipelined or padded response)
    /// must be dropped, not appended.
    func testTrailingBytesBeyondContentLengthAreTrimmed() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}EXTRA".utf8)
        let response = try XCTUnwrap(BridgeHTTPResponseParser.parse(raw))
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "{}")
    }

    // MARK: - Request serialisation

    func testRequestIncludesBearerAndLength() throws {
        let request = BridgeHTTPRequest(
            method: "POST",
            path: "/tap",
            body: Data("x=1&y=2".utf8),
            contentType: "application/x-www-form-urlencoded",
            bearerToken: "secret"
        )
        let text = try XCTUnwrap(String(data: request.serialized(host: "127.0.0.1:8412"), encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("POST /tap HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Authorization: Bearer secret\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 7\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\nx=1&y=2"))
    }

    func testRequestWithoutBodyStillDeclaresZeroLength() throws {
        let request = BridgeHTTPRequest(method: "GET", path: "/ping")
        let text = try XCTUnwrap(String(data: request.serialized(host: "h"), encoding: .utf8))
        XCTAssertTrue(text.contains("Content-Length: 0\r\n"))
        XCTAssertFalse(text.contains("Authorization"))
    }

    // MARK: - Form encoding

    /// Base64 payloads contain `+` and `/`. An unescaped `+` decodes to
    /// a space on the bridge side, which would silently corrupt every
    /// `type` and `paste` whose text happens to encode one.
    func testFormEncodingEscapesBase64PunctuationAndSeparators() {
        let encoded = IOSDeviceBridgeClient.formEncode(["base64_text": "aGVsbG8+d29ybGQ/Zm9v+bar/baz="])
        XCTAssertFalse(encoded.dropFirst("base64_text=".count).contains("+"))
        XCTAssertTrue(encoded.contains("%2B"))
        XCTAssertTrue(encoded.contains("%2F"))
        XCTAssertTrue(encoded.contains("%3D"))
    }

    func testFormEncodingIsDeterministic() {
        let fields = ["b": "2", "a": "1", "c": "3"]
        XCTAssertEqual(IOSDeviceBridgeClient.formEncode(fields), "a=1&b=2&c=3")
    }

    // MARK: - Ready-line handshake

    /// xcodebuild interleaves its own logging with test stdout, so the
    /// marker has to be recoverable from the middle of a noisy line.
    func testReadyMarkerIsRecoveredFromInterleavedOutput() throws {
        let log = """
        2026-07-27 01:48:44.746 xcodebuild[1:2] noise
            t =     0.03s Set UpSIMUSE_BRIDGE_READY->{"port":8412,"addresses":["192.168.1.109"],"protocol_version":1,"bridge_version":"0.1.0"}<-SIMUSE_BRIDGE_READY
        more noise
        """
        let payload = try XCTUnwrap(BridgeRunnerLauncher.parseMarker(log, marker: "SIMUSE_BRIDGE_READY"))
        let ready = try BridgeRunnerLauncher.decodeReady(payload)
        XCTAssertEqual(ready.port, 8412)
        XCTAssertEqual(ready.addresses, ["192.168.1.109"])
        XCTAssertEqual(ready.protocolVersion, 1)
        XCTAssertEqual(ready.bridgeVersion, "0.1.0")
    }

    func testAbsentMarkerReturnsNil() {
        XCTAssertNil(BridgeRunnerLauncher.parseMarker("nothing here", marker: "SIMUSE_BRIDGE_READY"))
    }

    /// A half-written line (the runner mid-flush) must not parse as a
    /// complete payload.
    func testUnterminatedMarkerReturnsNil() {
        XCTAssertNil(BridgeRunnerLauncher.parseMarker(#"SIMUSE_BRIDGE_READY->{"port":84"#, marker: "SIMUSE_BRIDGE_READY"))
    }

    func testFailureMarkerIsDistinctFromReady() {
        let log = #"SIMUSE_BRIDGE_FAILED->{"error":"bind(:8412) failed"}<-SIMUSE_BRIDGE_FAILED"#
        XCTAssertNil(BridgeRunnerLauncher.parseMarker(log, marker: "SIMUSE_BRIDGE_READY"))
        XCTAssertNotNil(BridgeRunnerLauncher.parseMarker(log, marker: "SIMUSE_BRIDGE_FAILED"))
    }

    // MARK: - xctestrun patching

    func testPatchInjectsTokenAndPortIntoEveryTestTarget() throws {
        let plist: [String: Any] = [
            "__xctestrun_metadata__": ["FormatVersion": 1],
            "SimUseDeviceBridgeRunner": [
                "TestHostPath": "__TESTROOT__/Debug-iphoneos/Runner.app",
                "EnvironmentVariables": ["TERM": "dumb"],
            ],
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("simuse-test-\(UUID().uuidString).xctestrun")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url)

        try BridgeRunnerLauncher.patchXCTestRun(at: url, token: "tok-123", port: 9001)

        let reloaded = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        )
        let target = try XCTUnwrap(reloaded["SimUseDeviceBridgeRunner"] as? [String: Any])
        let environment = try XCTUnwrap(target["EnvironmentVariables"] as? [String: Any])
        XCTAssertEqual(environment["SIMUSE_BRIDGE_TOKEN"] as? String, "tok-123")
        XCTAssertEqual(environment["SIMUSE_BRIDGE_PORT"] as? String, "9001")
        // Pre-existing entries must survive — Xcode puts real
        // configuration in here.
        XCTAssertEqual(environment["TERM"] as? String, "dumb")
        // The metadata block is not a test target and must be untouched.
        XCTAssertNotNil(reloaded["__xctestrun_metadata__"])
        XCTAssertNil((reloaded["__xctestrun_metadata__"] as? [String: Any])?["EnvironmentVariables"])
    }

    // MARK: - usbmux UDID normalisation

    /// usbmuxd reports the dash-less form on some macOS versions;
    /// `devicectl` always prints the dashed one. Comparing them raw
    /// makes a plugged-in phone look absent.
    func testUSBMuxUDIDNormalisation() {
        XCTAssertEqual(
            USBMuxTransport.normalizeUDID("00008150000E242411D9401C"),
            "00008150-000E242411D9401C"
        )
        XCTAssertEqual(
            USBMuxTransport.normalizeUDID("00008150-000E242411D9401C"),
            "00008150-000E242411D9401C"
        )
        let legacy = String(repeating: "ab", count: 20)
        XCTAssertEqual(USBMuxTransport.normalizeUDID(legacy), legacy)
    }

    // MARK: - Session store

    func testSessionRoundTripsAndRejectsTraversalUDIDs() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("simuse-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        let session = IOSDeviceBridgeSession(
            udid: "00008150-000E242411D9401C",
            token: "tok",
            port: 8412,
            addresses: ["192.168.1.9"],
            preferredHost: "192.168.1.9",
            launcherPID: 4242,
            xctestrunPath: "/tmp/x.xctestrun",
            bridgeVersion: "0.1.0",
            protocolVersion: 1
        )
        IOSDeviceBridgeSessionStore.write(session, home: home)
        let reloaded = try XCTUnwrap(IOSDeviceBridgeSessionStore.read(udid: session.udid, home: home))
        XCTAssertEqual(reloaded.udid, session.udid)
        XCTAssertEqual(reloaded.token, session.token)
        XCTAssertEqual(reloaded.port, session.port)
        XCTAssertEqual(reloaded.addresses, session.addresses)
        XCTAssertEqual(reloaded.preferredHost, session.preferredHost)
        XCTAssertEqual(reloaded.launcherPID, session.launcherPID)
        XCTAssertEqual(reloaded.xctestrunPath, session.xctestrunPath)
        XCTAssertEqual(reloaded.bridgeVersion, session.bridgeVersion)
        XCTAssertEqual(reloaded.protocolVersion, session.protocolVersion)
        // `startedAt` is stored as ISO-8601, which is second-resolution;
        // it round-trips to the same second, not the same Date.
        XCTAssertEqual(
            reloaded.startedAt.timeIntervalSince1970,
            session.startedAt.timeIntervalSince1970,
            accuracy: 1.0
        )

        // The token lives in this file; it must not be world-readable.
        let attributes = try FileManager.default.attributesOfItem(
            atPath: IOSDeviceBridgeSessionStore.file(for: session.udid, home: home).path
        )
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)

        XCTAssertFalse(IOSDeviceBridgeSessionStore.isValidUDID("../../etc/passwd"))
        XCTAssertFalse(IOSDeviceBridgeSessionStore.isValidUDID(".."))
        XCTAssertFalse(IOSDeviceBridgeSessionStore.isValidUDID(""))
        XCTAssertTrue(IOSDeviceBridgeSessionStore.isValidUDID("00008150-000E242411D9401C"))
    }

    /// A session whose launcher has exited is dead even though the file
    /// is intact — that is the common failure and the reason liveness is
    /// checked before any network call.
    func testLauncherLivenessTracksTheRecordedPID() {
        let live = IOSDeviceBridgeSession(
            udid: "00008150-000E242411D9401C", token: "t", port: 1, addresses: [],
            preferredHost: nil, launcherPID: getpid(), xctestrunPath: "",
            bridgeVersion: "", protocolVersion: 1
        )
        XCTAssertTrue(live.launcherIsAlive)

        let dead = IOSDeviceBridgeSession(
            udid: "00008150-000E242411D9401C", token: "t", port: 1, addresses: [],
            preferredHost: nil, launcherPID: 0, xctestrunPath: "",
            bridgeVersion: "", protocolVersion: 1
        )
        XCTAssertFalse(dead.launcherIsAlive)
    }

    // MARK: - devicectl parsing

    func testDeviceCtlParsesUsableAndUnusableDevices() throws {
        let usable = DeviceCtl.parseDevice([
            "hardwareProperties": ["udid": "00008150-000E242411D9401C", "marketingName": "iPhone 17 Pro"],
            "deviceProperties": ["name": "Daniel iPhone", "osVersionNumber": "27.0", "developerModeStatus": "enabled"],
            "connectionProperties": ["transportType": "localNetwork", "pairingState": "paired"],
        ])
        let device = try XCTUnwrap(usable)
        XCTAssertEqual(device.udid, "00008150-000E242411D9401C")
        XCTAssertEqual(device.osVersion, "27.0")
        XCTAssertTrue(device.developerModeEnabled)
        XCTAssertTrue(device.isUsable)

        // Developer Mode off ⇒ not usable, however well-paired.
        let noDevMode = try XCTUnwrap(DeviceCtl.parseDevice([
            "hardwareProperties": ["udid": "00008120-001669200A80C01E"],
            "deviceProperties": ["name": "Other iPhone"],
            "connectionProperties": ["transportType": "wired", "pairingState": "paired"],
        ]))
        XCTAssertFalse(noDevMode.developerModeEnabled)
        XCTAssertFalse(noDevMode.isUsable)

        XCTAssertNil(DeviceCtl.parseDevice(["deviceProperties": ["name": "no udid"]]))
    }

    // MARK: - Build cache key

    /// Changing team or Xcode must not reuse a runner the device will
    /// refuse to launch.
    func testBuildDirectoryVariesWithTeam() {
        let project = URL(fileURLWithPath: "/repo/ios-bridge")
        let home = URL(fileURLWithPath: "/home")
        let a = BridgeRunnerLauncher.buildDirectory(projectPath: project, teamID: "AAAA", home: home)
        let b = BridgeRunnerLauncher.buildDirectory(projectPath: project, teamID: "BBBB", home: home)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.path.hasPrefix("/home/.sim-use/ios-bridge/"))
    }

    /// Editing a handler must invalidate the cached build. Without this,
    /// `init` relaunches the previous runner and the change silently
    /// does not take effect.
    func testBuildDirectoryVariesWithSourceContents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("simuse-bridge-src-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let handler = sources.appendingPathComponent("KeyboardStateHandler.swift")
        try "let detection = \"snapshot\"".write(to: handler, atomically: true, encoding: .utf8)
        let home = URL(fileURLWithPath: "/home")
        let before = BridgeRunnerLauncher.buildDirectory(projectPath: root, teamID: "AAAA", home: home)

        try "let detection = \"focus\"".write(to: handler, atomically: true, encoding: .utf8)
        let after = BridgeRunnerLauncher.buildDirectory(projectPath: root, teamID: "AAAA", home: home)

        XCTAssertNotEqual(before, after, "a source edit must produce a different build directory")

        // ...and an unchanged tree must still hit the cache, or every
        // `init` pays a full rebuild.
        XCTAssertEqual(
            after,
            BridgeRunnerLauncher.buildDirectory(projectPath: root, teamID: "AAAA", home: home)
        )
    }

    /// File order from directory enumeration is not guaranteed stable;
    /// the fingerprint must not depend on it.
    func testSourceFingerprintIsOrderIndependent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("simuse-bridge-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "a".write(to: root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
        let first = BridgeRunnerLauncher.sourceFingerprint(root)
        XCTAssertEqual(first, BridgeRunnerLauncher.sourceFingerprint(root))
        XCTAssertNotEqual(first, "unfingerprinted")
    }
}
