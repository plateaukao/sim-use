// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Turns a `GesturePreset` into the `BridgeStroke` wire shape.
///
/// Shared by the Android bridge and the real-iOS-device bridge, which
/// accept byte-identical `/gesture` payloads — that was a deliberate
/// choice when the iOS bridge was designed, and this encoder is what
/// makes it pay off: pinch, zoom and rotate are expressed once and both
/// platforms dispatch the same trajectories.
///
/// Deliberately *not* responsible for display-bounds validation. Android
/// rejects out-of-bounds strokes at the framework level and needs a
/// pre-flight check with platform-specific remediation text; iOS clamps
/// silently. Each backend keeps its own policy.
public enum GesturePresetStrokeEncoder {

    /// Polyline segments used to approximate an arc. 16 keeps the max
    /// radial deviation under ~2% of the configured radius across sweeps
    /// up to a full circle — well below what touch recognisers resolve.
    public static let arcWaypointCount = 16

    public static func strokes(
        _ presetStrokes: [GesturePreset.Stroke],
        durationMilliseconds: Int
    ) -> [BridgeStroke] {
        presetStrokes.map { stroke in
            switch stroke.curve {
            case .linear:
                return .linear(
                    startX: stroke.startX, startY: stroke.startY,
                    endX: stroke.endX, endY: stroke.endY,
                    startTime: 0, duration: durationMilliseconds
                )
            case .arc:
                let waypoints: [BridgeStrokePoint] = (0...arcWaypointCount).map { index in
                    let t = Double(index) / Double(arcWaypointCount)
                    let point = stroke.point(at: t)
                    return BridgeStrokePoint(x: point.x, y: point.y)
                }
                return .polyline(points: waypoints, startTime: 0, duration: durationMilliseconds)
            }
        }
    }
}
