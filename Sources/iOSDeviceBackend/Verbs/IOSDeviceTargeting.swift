// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore
import iOSSimBackend

/// Turns the tap-family targeting flags into a point for the real-device
/// backend.
///
/// All three targeting forms carry over from the Simulator:
///
/// - Outline aliases (`@3`, `#2`) resolve against the same on-disk cache.
/// - Explicit coordinates pass straight through because the bridge
///   already speaks points in the tree's own space.
/// - Live AX selectors (`--label`, `--id`, `--element-type`, `--frame`)
///   fetch a **fresh** accessibility snapshot at act time and run the
///   Simulator's `AccessibilityTargetResolver` over it — the device
///   bridge emits the Simulator's tree shape precisely so this stack is
///   shared. The historical refusal here was about silently degrading to
///   the *cached* outline; a fresh fetch removes the staleness, at the
///   cost of the snapshot walk (2–4 s on device, and per poll tick with
///   `--wait-timeout`).
public enum IOSDeviceTargeting {

    public static func resolvePoint(
        alias: String?,
        x: Double?,
        y: Double?,
        point: CoordinatePair?,
        udid: String
    ) throws -> (x: Double, y: Double) {
        if let explicit = try TapCoordinateResolver.resolve(x: x, y: y, point: point) {
            return (explicit.x, explicit.y)
        }

        guard let alias, !alias.isEmpty else {
            throw CLIError(errorDescription: """
                Nothing to target. Pass an outline alias (`@3`, `#2`) from the most recent \
                `describe-ui`, a live selector (`--label`, `--id`, …), or explicit --x / --y \
                coordinates.
                """)
        }
        let resolved = try OutlineAliasResolver.resolve(alias, udid: udid)
        return resolved.point
    }

    /// Live selector resolution: fresh tree fetch → shared resolver,
    /// with the Simulator's poller providing the `--wait-timeout` retry
    /// semantics (retry on not-found/ambiguous until the deadline). The
    /// calibration slot stays nil — device coordinates are already in
    /// the tree's own UI space, so there is no framebuffer transform.
    @MainActor
    public static func resolveLiveTarget(
        targeting: TapTargetingOptions,
        aliasID: String? = nil,
        waitTimeout: Double,
        pollInterval: Double,
        udid: String,
        logger: SimUseLogger,
        controller: IOSDeviceController = IOSDeviceController()
    ) async throws -> AccessibilityPoller.ResolvedHIDTarget {
        let query: AccessibilityQuery
        if let aliasID {
            query = .id(aliasID)
        } else if let elementID = targeting.elementID {
            query = .id(elementID)
        } else if let elementLabel = targeting.elementLabel {
            query = .label(elementLabel)
        } else if let elementValue = targeting.elementValue {
            query = .value(elementValue)
        } else if let labelContains = targeting.labelContains {
            query = .labelContains(labelContains)
        } else if let labelRegex = targeting.labelRegex {
            query = .labelRegex(pattern: labelRegex)
        } else {
            throw CLIError(errorDescription: """
                --element-type / --frame narrow a selector but cannot stand alone. Add \
                --label, --label-contains, --label-regex, --id, or --value (or use an \
                outline alias / explicit coordinates).
                """)
        }

        let client = try controller.client(udid: udid)
        return try await AccessibilityPoller.resolveWithPollingHIDTarget(
            query: query,
            simulatorUDID: udid,
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            elementType: targeting.elementType,
            frameFilter: IOSSimTapCommand.frameFilter(from: targeting),
            rootsProvider: { _ in
                // filter: true drops zero-size leaves on-device. They are
                // untappable (the resolver rejects a zero-size winner), so
                // keeping them can only create phantom ambiguity — a
                // SpringBoard icon carries a second, 0×0 copy of its
                // AXUniqueId that would turn every `--id` into
                // "Multiple (2) elements matched".
                let tree = try client.fetchTree(filter: true)
                let roots = try JSONDecoder().decode([AccessibilityElement].self, from: tree.elementsJSON)
                return (roots: roots, calibration: nil)
            },
            logger: logger
        )
    }
}
