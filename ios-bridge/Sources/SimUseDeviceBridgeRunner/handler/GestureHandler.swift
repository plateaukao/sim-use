// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest

/// `/tap`, `/swipe`, `/gesture` — the device counterpart of the Android
/// bridge's `GestureHandler`.
///
/// Coordinates are in the foreground application's UI space, the same
/// space the `/a11y_tree_full` frames are expressed in, so a coordinate
/// read out of the outline can be handed straight back without a
/// transform. The event system is told the current interface
/// orientation and does the mapping to physical touches itself — which
/// is why this needs none of the framebuffer↔UI calibration the
/// Simulator HID path requires (`OrientationCalibrator`): there, HID
/// events bypass UIKit entirely, whereas here they go through the same
/// synthesizer XCUITest uses for `XCUICoordinate.tap()`.
final class GestureHandler {

    /// Sampling rate for interpolated drag paths. 60 Hz matches the
    /// display refresh floor; denser sampling produces more touch-move
    /// events than UIKit coalesces anyway.
    private static let dragSampleInterval: TimeInterval = 1.0 / 60.0

    /// Android's wire uses milliseconds for stroke timings; so do we,
    /// for parity. The event API wants seconds.
    private static let msToSeconds = 0.001

    func tap(params: [String: String]) -> HTTPResponse {
        guard let x = params["x"].flatMap(Double.init) else { return Self.badRequest("missing_x") }
        guard let y = params["y"].flatMap(Double.init) else { return Self.badRequest("missing_y") }
        // `duration` turns a tap into a long-press. 0 still needs a
        // non-zero lift offset or the event collapses to a single
        // instant and UIKit's gesture recognizers can miss it entirely.
        let duration = params["duration"].flatMap(Double.init).map { $0 * Self.msToSeconds } ?? 0
        let holdFor = max(duration, 0.02)

        let stroke = [
            waypoint(x: x, y: y, t: 0),
            waypoint(x: x, y: y, t: holdFor),
        ]
        return perform([stroke], params: params, failureCode: "tap_failed")
    }

    func swipe(params: [String: String]) -> HTTPResponse {
        guard let startX = params["startX"].flatMap(Double.init) else { return Self.badRequest("missing_startX") }
        guard let startY = params["startY"].flatMap(Double.init) else { return Self.badRequest("missing_startY") }
        guard let endX = params["endX"].flatMap(Double.init) else { return Self.badRequest("missing_endX") }
        guard let endY = params["endY"].flatMap(Double.init) else { return Self.badRequest("missing_endY") }
        let duration = (params["duration"].flatMap(Double.init) ?? 300) * Self.msToSeconds

        let stroke = Self.interpolate(
            from: CGPoint(x: startX, y: startY),
            to: CGPoint(x: endX, y: endY),
            startTime: 0,
            duration: duration
        )
        return perform([stroke], params: params, failureCode: "swipe_failed")
    }

    /// Multi-stroke gestures (pinch, rotate, two-finger drag). Wire
    /// format is identical to the Android bridge's `/gesture`: a JSON
    /// array of `{startX,startY,endX,endY,startTime,duration,path?}`,
    /// times in milliseconds, so the host's `BridgeStroke` encoder is
    /// shared across both platforms.
    func gesture(params: [String: String]) -> HTTPResponse {
        guard let raw = params["strokes"] else { return Self.badRequest("missing_strokes") }
        guard
            let data = raw.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            !parsed.isEmpty
        else {
            return Self.badRequest("invalid_strokes")
        }

        var strokes: [[[String: NSNumber]]] = []
        for descriptor in parsed {
            guard
                let startX = Self.double(descriptor["startX"]),
                let startY = Self.double(descriptor["startY"]),
                let endX = Self.double(descriptor["endX"]),
                let endY = Self.double(descriptor["endY"])
            else {
                return Self.badRequest("invalid_strokes")
            }
            let startTime = (Self.double(descriptor["startTime"]) ?? 0) * Self.msToSeconds
            let duration = (Self.double(descriptor["duration"]) ?? 300) * Self.msToSeconds

            // An explicit `path` carries arc-shaped strokes (rotate) as
            // a polyline; without one the stroke is the straight chord
            // between start and end, matching the Android bridge.
            if let path = descriptor["path"] as? [[String: Any]], path.count >= 2 {
                let step = duration / Double(path.count - 1)
                var stroke: [[String: NSNumber]] = []
                for (index, point) in path.enumerated() {
                    guard let px = Self.double(point["x"]), let py = Self.double(point["y"]) else {
                        return Self.badRequest("invalid_strokes")
                    }
                    stroke.append(waypoint(x: px, y: py, t: startTime + step * Double(index)))
                }
                strokes.append(stroke)
            } else {
                strokes.append(Self.interpolate(
                    from: CGPoint(x: startX, y: startY),
                    to: CGPoint(x: endX, y: endY),
                    startTime: startTime,
                    duration: duration
                ))
            }
        }
        return perform(strokes, params: params, failureCode: "gesture_failed")
    }

    // MARK: - Shared

    private func perform(
        _ strokes: [[[String: NSNumber]]],
        params: [String: String],
        failureCode: String
    ) -> HTTPResponse {
        let orientation = SimUsePrivateAPI.interfaceOrientation(forBundleID: params["bundle_id"] ?? foregroundBundleID())
        do {
            try SimUsePrivateAPI.performTouchStrokes(strokes, interfaceOrientation: orientation)
            return HTTPResponse(status: 200, json: Envelope.success())
        } catch {
            return HTTPResponse(status: 500, json: Envelope.error(
                code: failureCode,
                message: error.localizedDescription
            ))
        }
    }

    private func foregroundBundleID() -> String? {
        SimUsePrivateAPI.activeForegroundBundleIDs().first
    }

    private func waypoint(x: Double, y: Double, t: TimeInterval) -> [String: NSNumber] {
        ["x": NSNumber(value: x), "y": NSNumber(value: y), "t": NSNumber(value: t)]
    }

    /// Straight-line drag sampled at `dragSampleInterval`. A two-point
    /// stroke would be delivered as down-here/up-there with no movement
    /// in between, which UIKit's pan recognizers read as a tap plus a
    /// teleport rather than a swipe — scroll views in particular ignore
    /// it entirely.
    private static func interpolate(
        from start: CGPoint,
        to end: CGPoint,
        startTime: TimeInterval,
        duration: TimeInterval
    ) -> [[String: NSNumber]] {
        let steps = max(2, Int((duration / dragSampleInterval).rounded()))
        return (0...steps).map { index in
            let progress = Double(index) / Double(steps)
            return [
                "x": NSNumber(value: start.x + (end.x - start.x) * progress),
                "y": NSNumber(value: start.y + (end.y - start.y) * progress),
                "t": NSNumber(value: startTime + duration * progress),
            ]
        }
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }

    static func badRequest(_ code: String) -> HTTPResponse {
        HTTPResponse(status: 400, json: Envelope.error(code: code))
    }
}
