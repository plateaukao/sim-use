// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import SimUseCore

/// The encoder is the piece both bridges (Android APK, iOS device
/// runner) rely on for byte-identical `/gesture` payloads. These tests
/// pin the wire-visible invariants: linear strokes stay chord-only,
/// arcs sample into a polyline whose chord fields mirror its endpoints.
final class GesturePresetStrokeEncoderTests: XCTestCase {

    func testPinchEncodesLinearStrokesWithoutPath() {
        let presetStrokes = GesturePreset.pinchOut.strokes(
            screenWidth: 390, screenHeight: 844,
            scale: nil, angle: nil,
            centerX: nil, centerY: nil, radius: nil
        )
        let encoded = GesturePresetStrokeEncoder.strokes(presetStrokes, durationMilliseconds: 500)

        XCTAssertEqual(encoded.count, 2)
        for (preset, wire) in zip(presetStrokes, encoded) {
            XCTAssertNil(wire.path, "pinch strokes are straight lines — no polyline expected")
            XCTAssertEqual(wire.startX, preset.startX)
            XCTAssertEqual(wire.startY, preset.startY)
            XCTAssertEqual(wire.endX, preset.endX)
            XCTAssertEqual(wire.endY, preset.endY)
            XCTAssertEqual(wire.startTime, 0)
            XCTAssertEqual(wire.duration, 500)
        }
    }

    func testRotateEncodesArcsAsPolylinesWithChordFallback() {
        let presetStrokes = GesturePreset.rotateCw.strokes(
            screenWidth: 390, screenHeight: 844,
            scale: nil, angle: 90,
            centerX: nil, centerY: nil, radius: 80
        )
        let encoded = GesturePresetStrokeEncoder.strokes(presetStrokes, durationMilliseconds: 700)

        XCTAssertEqual(encoded.count, 2)
        for (preset, wire) in zip(presetStrokes, encoded) {
            guard let path = wire.path else {
                XCTFail("rotate strokes must carry a sampled polyline")
                continue
            }
            XCTAssertEqual(path.count, GesturePresetStrokeEncoder.arcWaypointCount + 1)
            // Chord fields mirror the polyline endpoints so a bridge
            // that ignores `path` still draws a sensible straight line.
            XCTAssertEqual(wire.startX, path.first!.x)
            XCTAssertEqual(wire.startY, path.first!.y)
            XCTAssertEqual(wire.endX, path.last!.x)
            XCTAssertEqual(wire.endY, path.last!.y)
            XCTAssertEqual(wire.startX, preset.startX, accuracy: 0.0001)
            XCTAssertEqual(wire.endX, preset.endX, accuracy: 0.0001)
            XCTAssertEqual(wire.duration, 700)
        }
    }

    /// Every sampled waypoint of a rotate must stay on the circle —
    /// this is what the polyline representation exists to preserve.
    func testRotatePolylineWaypointsStayOnTheCircle() {
        let radius = 80.0
        let center = (x: 195.0, y: 422.0)
        let presetStrokes = GesturePreset.rotateCcw.strokes(
            screenWidth: 390, screenHeight: 844,
            scale: nil, angle: 180,
            centerX: center.x, centerY: center.y, radius: radius
        )
        let encoded = GesturePresetStrokeEncoder.strokes(presetStrokes, durationMilliseconds: 1000)

        for wire in encoded {
            for point in wire.path ?? [] {
                let distance = ((point.x - center.x) * (point.x - center.x)
                    + (point.y - center.y) * (point.y - center.y)).squareRoot()
                XCTAssertEqual(distance, radius, accuracy: radius * 0.02)
            }
        }
    }
}
