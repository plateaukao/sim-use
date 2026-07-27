// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Turns the tap-family targeting flags into a point for the real-device
/// backend.
///
/// Two of the three targeting forms carry over from the Simulator:
/// outline aliases (`@3`, `#2`) resolve against the same on-disk cache,
/// and explicit coordinates pass straight through because the bridge
/// already speaks points in the tree's own space.
///
/// The third — live AX selectors (`--label`, `--id`, `--element-type`) —
/// deliberately does not. Those work on the Simulator by re-querying the
/// accessibility tree at tap time and hit-testing; the device bridge has
/// no point-query endpoint, so honouring them would mean silently
/// falling back to the cached outline and tapping whatever was there
/// during the last `describe-ui`. Refusing is the safer contract: a
/// wrong tap on a real phone is not recoverable the way a wrong tap on a
/// simulator is.
public enum IOSDeviceTargeting {

    public static func resolvePoint(
        alias: String?,
        x: Double?,
        y: Double?,
        point: CoordinatePair?,
        selectorInUse: Bool,
        udid: String
    ) throws -> (x: Double, y: Double) {
        if selectorInUse {
            throw CLIError(errorDescription: """
                AX selectors (--label, --id, --element-type, …) are not supported on real iOS \
                devices yet — they need a live point-query the on-device bridge does not expose.

                Run `sim-use describe-ui --device \(udid)` and tap the alias it prints instead:
                  sim-use tap @3 --device \(udid)
                """)
        }

        if let explicit = try TapCoordinateResolver.resolve(x: x, y: y, point: point) {
            return (explicit.x, explicit.y)
        }

        guard let alias, !alias.isEmpty else {
            throw CLIError(errorDescription: """
                Nothing to target. Pass an outline alias (`@3`, `#2`) from the most recent \
                `describe-ui`, or explicit --x / --y coordinates.
                """)
        }
        let resolved = try OutlineAliasResolver.resolve(alias, udid: udid)
        return resolved.point
    }
}
