// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// Shared `--device` flag for `sim-use ios-device <verb>`.
///
/// Same shape as `AndroidDeviceOptions`, and for the same reason: there
/// is no "the one obvious target" to fall back on, and letting the
/// iOS-*Simulator* `DeviceResolver` auto-pick here would answer a
/// real-device command with a "no simulator booted" error from the
/// wrong backend.
///
/// Unlike Android, though, a single connected iPhone *is* usually
/// unambiguous, so when exactly one device is both paired and usable we
/// pick it. Anything else asks.
public struct IOSDeviceOptions: ParsableArguments {
    @Option(
        name: .customLong("device"),
        help: "Real iOS device UDID (e.g. `00008150-000E242411D9401C`). Optional when exactly one usable device is connected."
    )
    public var device: String?

    @Option(
        name: .customLong("udid"),
        help: ArgumentHelp("Deprecated alias for --device.", visibility: .default)
    )
    public var udid: String?

    /// Resolved device UDID. Empty until `resolve()` runs.
    public var resolved: String = ""

    public init() {}

    public mutating func resolve(lister: DeviceCtl = DeviceCtl()) throws {
        if let explicit = try DeviceOptions.selectExplicit(device: device, udid: udid) {
            resolved = explicit
            return
        }
        if let fromEnvironment = ProcessInfo.processInfo.environment["SIM_USE_IOS_DEVICE"], !fromEnvironment.isEmpty {
            resolved = fromEnvironment
            return
        }

        let usable = ((try? lister.devices()) ?? []).filter(\.isUsable)
        if usable.count == 1, let only = usable.first {
            resolved = only.udid
            return
        }
        if usable.isEmpty {
            throw CLIError(errorDescription: """
                No usable iOS device found. Connect an iPhone or iPad over USB (or Wi-Fi with \
                "Connect via network" enabled in Xcode), trust this Mac, and enable Developer Mode \
                under Settings → Privacy & Security. Run `sim-use ios-device devices` to see what is visible.
                """)
        }
        let names = usable.map { "  \($0.udid)  \($0.name)" }.joined(separator: "\n")
        throw CLIError(errorDescription: """
            More than one usable iOS device is connected — pass --device <udid>:
            \(names)
            """)
    }
}
