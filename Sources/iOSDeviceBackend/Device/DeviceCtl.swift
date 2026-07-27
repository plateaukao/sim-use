// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Thin wrapper over `xcrun devicectl`, the supported CLI for real
/// devices since Xcode 15.
///
/// This is the iOS-device analogue of `Adb` — but far thinner, because
/// `devicectl` is only used for *discovery*. Everything interactive
/// (tapping, reading the UI, screenshots) goes through the on-device
/// bridge; `devicectl` cannot do any of it.
public struct DeviceCtl: Sendable {
    public init() {}

    public struct Device: Sendable, Equatable {
        public let udid: String
        public let name: String
        public let marketingName: String?
        public let osVersion: String?
        /// `available`, `unavailable`, `connecting`, …
        public let state: String
        /// `wired`, `localNetwork`, or nil when not connected.
        public let transport: String?
        public let developerModeEnabled: Bool

        /// Whether sim-use can start a bridge session on this device
        /// right now. Mirrors `Adb.Device.isOnline`.
        public var isUsable: Bool {
            state.hasPrefix("available") && developerModeEnabled
        }
    }

    public enum DeviceCtlError: Error, LocalizedError {
        case unavailable(String)
        case listFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let detail):
                return "`xcrun devicectl` is unavailable: \(detail). Real-device support needs Xcode 15 or newer."
            case .listFailed(let detail):
                return "`xcrun devicectl list devices` failed: \(detail)"
            }
        }
    }

    /// Enumerates paired devices.
    ///
    /// `devicectl` has no plain-text listing worth parsing — the table
    /// it prints truncates names and omits developer-mode state — so we
    /// always take the JSON path through a temporary file, which is the
    /// only output form it offers.
    public func devices() throws -> [Device] {
        let output = try runJSON(arguments: ["list", "devices"])
        guard let result = output["result"] as? [String: Any],
              let raw = result["devices"] as? [[String: Any]] else {
            return []
        }
        return raw.compactMap(Self.parseDevice)
    }

    static func parseDevice(_ entry: [String: Any]) -> Device? {
        guard
            let hardware = entry["hardwareProperties"] as? [String: Any],
            let udid = hardware["udid"] as? String
        else { return nil }

        let properties = entry["deviceProperties"] as? [String: Any]
        let connection = entry["connectionProperties"] as? [String: Any]

        return Device(
            udid: udid,
            name: properties?["name"] as? String ?? udid,
            marketingName: hardware["marketingName"] as? String,
            osVersion: properties?["osVersionNumber"] as? String,
            state: connection?["tunnelState"] as? String == "connected"
                ? "available"
                : (Self.availability(entry) ?? "unavailable"),
            transport: connection?["transportType"] as? String,
            // Absent on devices that have never been unlocked with the
            // Mac trusted; treat that as "not enabled" so the error
            // message points at the right fix.
            developerModeEnabled: (properties?["developerModeStatus"] as? String) == "enabled"
        )
    }

    /// `devicectl` reports availability in a few different places
    /// depending on how the device is attached. Prefer the explicit
    /// field, then infer from pairing + transport.
    private static func availability(_ entry: [String: Any]) -> String? {
        let connection = entry["connectionProperties"] as? [String: Any]
        if let paired = connection?["pairingState"] as? String, paired == "paired",
           let transport = connection?["transportType"] as? String, !transport.isEmpty {
            return "available"
        }
        return nil
    }

    /// Devices reshaped into sim-use's unified `Device` model, for the
    /// top-level `sim-use devices` table.
    public func listUnifiedDevices(onlineOnly: Bool = false) throws -> [SimUseCore.Device] {
        let raw = try devices()
        let filtered = onlineOnly ? raw.filter(\.isUsable) : raw
        return filtered.map { device in
            SimUseCore.Device(
                udid: device.udid,
                name: device.name,
                platform: .iosDevice,
                state: device.state,
                runtime: device.osVersion.map { "iOS \($0)" } ?? "iOS"
            )
        }
    }

    // MARK: - Process plumbing

    private func runJSON(arguments: [String]) throws -> [String: Any] {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-use-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl"] + arguments + ["--json-output", temporary.path]
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw DeviceCtlError.unavailable(error.localizedDescription)
        }
        // Read stderr before waiting: devicectl is chatty about
        // provisioning and can fill the pipe buffer, which would
        // deadlock a wait-then-read ordering.
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let data = try? Data(contentsOf: temporary) else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "no output"
            throw DeviceCtlError.listFailed(detail)
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            throw DeviceCtlError.listFailed("output was not a JSON object")
        }
        return json
    }
}
