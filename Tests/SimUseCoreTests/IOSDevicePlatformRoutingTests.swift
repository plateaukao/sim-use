// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import SimUseCore

/// Real-device UDIDs used to be swallowed by the Android branch: the
/// modern 25-character form is hex-and-one-dash, which fits inside adb's
/// 4–32 length window and passes its character filter. Every `sim-use
/// tap --device 00008150-…` would have gone looking for an adb serial.
/// These tests pin the ordering that fixes it.
final class IOSDevicePlatformRoutingTests: XCTestCase {

    func testModernDeviceUDIDRoutesToIOSDevice() {
        XCTAssertEqual(PlatformRouter.resolve(udid: "00008150-000E242411D9401C"), .iOSDevice)
        XCTAssertEqual(PlatformRouter.resolve(udid: "00008112-001851123C07401E"), .iOSDevice)
    }

    func testLegacyFortyCharacterUDIDRoutesToIOSDevice() {
        let legacy = String(repeating: "a1b2c3d4", count: 5) // 40 hex characters
        XCTAssertEqual(legacy.count, 40)
        XCTAssertEqual(PlatformRouter.resolve(udid: legacy), .iOSDevice)
    }

    /// The regression this ordering exists for.
    func testDeviceUDIDIsNotClassifiedAsAndroid() {
        XCTAssertFalse(PlatformRouter.looksLikeAndroid("00008150-000E242411D9401C"))
    }

    func testSimulatorUDIDStillRoutesToSimulator() {
        XCTAssertEqual(PlatformRouter.resolve(udid: "870B287D-B25F-45FC-A198-DC8BAC1A9CE5"), .iOSSim)
        XCTAssertFalse(PlatformRouter.looksLikeIOSDevice("870B287D-B25F-45FC-A198-DC8BAC1A9CE5"))
    }

    func testAndroidSerialsStillRouteToAndroid() {
        XCTAssertEqual(PlatformRouter.resolve(udid: "emulator-5554"), .android)
        XCTAssertEqual(PlatformRouter.resolve(udid: "RFFNW00H4WK"), .android)
        XCTAssertEqual(PlatformRouter.resolve(udid: "192.168.1.5:5555"), .android)
    }

    /// A serial that happens to be hex but has the wrong group sizes
    /// must not be mistaken for a device.
    func testNearMissShapesAreNotIOSDevices() {
        XCTAssertFalse(PlatformRouter.looksLikeIOSDevice("0000815-000E242411D9401C"))   // 7 + 16
        XCTAssertFalse(PlatformRouter.looksLikeIOSDevice("00008150-000E242411D9401"))   // 8 + 15
        XCTAssertFalse(PlatformRouter.looksLikeIOSDevice("00008150-000E242411D9401CZ")) // non-hex
        XCTAssertFalse(PlatformRouter.looksLikeIOSDevice("00008150000E242411D9401C"))   // no dash, 24 chars
        XCTAssertFalse(PlatformRouter.looksLikeIOSDevice("emulator-5554"))
    }

    func testEmptyAndWhitespaceResolveToNil() {
        XCTAssertNil(PlatformRouter.resolve(udid: ""))
        XCTAssertNil(PlatformRouter.resolve(udid: "   "))
    }
}
