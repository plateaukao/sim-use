// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import iOSDeviceBackend

/// Dimension math for the real-device recorder: H.264 encoders reject
/// odd dimensions, so every scaled size must round down to even.
final class ScreenRecordingSinkTests: XCTestCase {

    func testFullScaleKeepsNativeDimensions() {
        let dims = ScreenRecordingSink.scaledEvenDimensions(width: 1206, height: 2622, scale: 1.0)
        XCTAssertEqual(dims.width, 1206)
        XCTAssertEqual(dims.height, 2622)
    }

    func testHalfScaleRoundsDownToEven() {
        // 1206 * 0.5 = 603 (odd) → 602; 2622 * 0.5 = 1311 (odd) → 1310.
        let dims = ScreenRecordingSink.scaledEvenDimensions(width: 1206, height: 2622, scale: 0.5)
        XCTAssertEqual(dims.width, 602)
        XCTAssertEqual(dims.height, 1310)
    }

    func testTinyScaleClampsToMinimumEvenSize() {
        let dims = ScreenRecordingSink.scaledEvenDimensions(width: 100, height: 100, scale: 0.001)
        XCTAssertEqual(dims.width, 2)
        XCTAssertEqual(dims.height, 2)
    }

    func testCaptureDeviceIDNormalization() {
        // The DAL device's uniqueID has carried the UDID both with and
        // without the hyphen across macOS releases.
        XCTAssertEqual(
            IOSDeviceScreenRecorder.normalizedID("00008150-000E242411D9401C"),
            IOSDeviceScreenRecorder.normalizedID("00008150000E242411D9401C")
        )
    }
}
