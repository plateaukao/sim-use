// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore

/// `sim-use ios-device describe-ui` — the outline of what is on screen.
public struct IOSDeviceDescribeUICommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "describe-ui",
        abstract: "Describe the UI hierarchy of a real iOS device.",
        aliases: ["ui"]
    )

    @OptionGroup public var device: IOSDeviceOptions

    @Option(name: .customLong("bundle-id"), help: "Snapshot a specific app instead of whatever is in the foreground (advanced).")
    public var bundleID: String?

    @Flag(name: .customLong("filter"), help: "Drop zero-size leaf elements from the tree before rendering.")
    public var filter: Bool = false

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {...}}` envelope including the raw tree.")
    public var jsonOutput: Bool = false

    public init() {}

    public typealias ExecutionResult = DescribeUIResult

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> DescribeUIResult {
        try IOSDeviceController().describeUI(
            udid: device.resolved,
            filter: filter,
            bundleID: bundleID,
            includeRaw: jsonOutput
        )
    }

    public func format(_ result: DescribeUIResult) -> CommandOutput {
        .raw(result.outline)
    }
}

/// `sim-use ios-device tap` — tap a coordinate or an outline alias.
public struct IOSDeviceTapCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tap",
        abstract: "Tap a point or an outline alias (`@3`, `#2`) on a real iOS device.",
        discussion: """
        Aliases resolve against the outline cache written by the most recent
        `describe-ui` for this device, exactly as on the Simulator and Android.
        Run `describe-ui` first if the screen has changed.

        Coordinates are in points, in the same space `describe-ui` reports —
        no conversion needed.
        """
    )

    @OptionGroup public var device: IOSDeviceOptions

    @Argument(help: "Outline alias to tap (`@3`, `#2`, `#2@1`). Omit when using --x / --y.")
    public var alias: String?

    @Option(name: .customLong("x"), help: "X coordinate in points.")
    public var x: Double?

    @Option(name: .customLong("y"), help: "Y coordinate in points.")
    public var y: Double?

    @Option(name: .customLong("duration"), help: "Hold duration in milliseconds; makes this a long-press.")
    public var durationMilliseconds: Int?

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {...}}` envelope.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public let x: Double
        public let y: Double
        public let target: String
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func validate() throws {
        let hasCoordinates = x != nil && y != nil
        if alias == nil && !hasCoordinates {
            throw ValidationError("Pass an alias (`@3`) or both --x and --y.")
        }
        if alias != nil && (x != nil || y != nil) {
            throw ValidationError("Pass either an alias or --x/--y, not both.")
        }
        if !hasCoordinates && (x != nil || y != nil) {
            throw ValidationError("--x and --y must be given together.")
        }
    }

    public func execute() async throws -> ExecutionResult {
        let controller = IOSDeviceController()
        let client = try controller.client(udid: device.resolved)

        let point: (x: Double, y: Double)
        let target: String
        if let alias {
            let resolved = try OutlineAliasResolver.resolve(alias, udid: device.resolved)
            point = resolved.point
            target = resolved.humanDescription
        } else {
            point = (x!, y!)
            target = "(\(Int(x!)), \(Int(y!)))"
        }

        try client.tap(x: point.x, y: point.y, durationMilliseconds: durationMilliseconds)
        return ExecutionResult(x: point.x, y: point.y, target: target)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line("Tapped \(result.target)")
    }
}

/// `sim-use ios-device swipe` — drag between two points.
public struct IOSDeviceSwipeCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "swipe",
        abstract: "Swipe between two points on a real iOS device."
    )

    @OptionGroup public var device: IOSDeviceOptions

    @Option(name: .customLong("start-x")) public var startX: Double
    @Option(name: .customLong("start-y")) public var startY: Double
    @Option(name: .customLong("end-x")) public var endX: Double
    @Option(name: .customLong("end-y")) public var endY: Double

    @Option(name: .customLong("duration"), help: "Swipe duration in milliseconds (default 300).")
    public var durationMilliseconds: Int = 300

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {...}}` envelope.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public let startX: Double
        public let startY: Double
        public let endX: Double
        public let endY: Double
        public let durationMilliseconds: Int
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        let client = try IOSDeviceController().client(udid: device.resolved)
        try client.swipe(
            startX: startX, startY: startY,
            endX: endX, endY: endY,
            durationMilliseconds: durationMilliseconds
        )
        return ExecutionResult(
            startX: startX, startY: startY,
            endX: endX, endY: endY,
            durationMilliseconds: durationMilliseconds
        )
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line("Swiped (\(Int(result.startX)), \(Int(result.startY))) → (\(Int(result.endX)), \(Int(result.endY))) over \(result.durationMilliseconds)ms")
    }
}

/// `sim-use ios-device type` — send text to whatever has keyboard focus.
public struct IOSDeviceTypeCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text into the focused field on a real iOS device.",
        discussion: """
        Text goes to whatever currently holds keyboard focus, so tap a field
        first. `--no-clear` appends instead of replacing the field's contents.

        For text the on-screen keyboard cannot produce (emoji, many non-Latin
        scripts), use `paste` instead.
        """
    )

    @OptionGroup public var device: IOSDeviceOptions

    @Argument(help: "Text to type.")
    public var text: String

    @Flag(name: .customLong("no-clear"), inversion: .prefixedNo, help: "Clear the field before typing (default: clear).")
    public var clear: Bool = true

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {...}}` envelope.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public let characters: Int
        public let cleared: Bool
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        let client = try IOSDeviceController().client(udid: device.resolved)
        let cleared = try client.type(text: text, clear: clear)
        if clear && !cleared {
            throw CLIError(errorDescription: """
                Typed \(text.count) characters, but the field could not be emptied first — \
                the new text was appended to what was already there. Clear it through the \
                app's own UI (a clear button, or select-all + delete) and retry, or pass \
                --no-clear if appending was intended.
                """)
        }
        return ExecutionResult(characters: text.count, cleared: clear)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line("Typed \(result.characters) character\(result.characters == 1 ? "" : "s")\(result.cleared ? " (field cleared first)" : "")")
    }
}

/// `sim-use ios-device paste` — clipboard + Cmd+V.
public struct IOSDevicePasteCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "paste",
        abstract: "Paste text into the focused field on a real iOS device.",
        discussion: """
        Puts the text on the system pasteboard and delivers a synthesized
        Cmd+V, the same route the Simulator backend uses.

        iOS 16+ may show an "Allow Paste?" consent alert the first time an app
        reads a pasteboard it did not write. The alert belongs to SpringBoard,
        so it appears in `describe-ui` and can be tapped like any other button.
        """
    )

    @OptionGroup public var device: IOSDeviceOptions

    @Argument(help: "Text to paste.")
    public var text: String

    @Flag(name: .customLong("replace"), help: "Select the field's contents first so the paste overwrites.")
    public var replace: Bool = false

    @Flag(name: .customLong("clipboard-only"), help: "Set the pasteboard but do not send Cmd+V.")
    public var clipboardOnly: Bool = false

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {...}}` envelope.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public let characters: Int
        public let pasted: Bool
        public let verified: Bool
        public let clipboardSet: Bool
        public let reason: String?
        public let hint: String?
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        let client = try IOSDeviceController().client(udid: device.resolved)
        let result = try client.paste(text: text, replace: replace, clipboardOnly: clipboardOnly)
        // A paste the device demonstrably ignored is a failure, not a
        // footnote. Reporting it as success is how `example.comå√` got
        // written to a field while the CLI printed "Pasted 37
        // characters."
        if !clipboardOnly, result.verified, !result.pasted {
            throw CLIError(errorDescription: """
                The text was copied to the device pasteboard, but it did not reach the field.
                \(result.hint ?? "Cmd+V was not honoured by the active keyboard.")
                """)
        }
        return ExecutionResult(
            characters: text.count,
            pasted: result.pasted,
            verified: result.verified,
            clipboardSet: result.clipboardSet,
            reason: result.reason,
            hint: result.hint
        )
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        if !result.pasted {
            return .line("Copied \(result.characters) characters to the device pasteboard.")
        }
        var lines = ["Pasted \(result.characters) characters." + (result.verified ? "" : " (unverified)")]
        if !result.verified, let hint = result.hint { lines.append("  \(hint)") }
        return .lines(lines)
    }
}

/// `sim-use ios-device screenshot` — PNG of the whole screen.
public struct IOSDeviceScreenshotCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a screenshot from a real iOS device."
    )

    @OptionGroup public var device: IOSDeviceOptions

    @Option(name: .shortAndLong, help: "Output PNG path. Defaults to ./screenshot-<timestamp>.png.")
    public var output: String?

    @Option(name: .customLong("scale"), help: "Downsample on the device before transfer, 0 < scale < 1. A full-resolution capture is several megabytes.")
    public var scale: Double?

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {path, bytes}}` envelope.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public let path: String
        public let bytes: Int
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func validate() throws {
        if let scale, scale <= 0 || scale >= 1 {
            throw ValidationError("--scale must be between 0 and 1 (exclusive).")
        }
    }

    public func execute() async throws -> ExecutionResult {
        let client = try IOSDeviceController().client(udid: device.resolved)
        let data = try client.screenshot(scale: scale)

        let path = output ?? Self.defaultPath()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try data.write(to: url, options: [.atomic])
        return ExecutionResult(path: url.path, bytes: data.count)
    }

    private static func defaultPath() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "screenshot-\(formatter.string(from: Date())).png"
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line("Wrote \(result.path) (\(result.bytes) bytes)")
    }
}

/// `sim-use ios-device keyboard-state` — is the keyboard up?
public struct IOSDeviceKeyboardStateCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "keyboard-state",
        abstract: "Report whether the on-screen keyboard is visible."
    )

    @OptionGroup public var device: IOSDeviceOptions

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {visible, ...}}` envelope.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public let visible: Bool
        public let owner: String?
        public let top: Double?
        /// Which bridge-side strategy answered. `focus` means the
        /// keyboard was inferred from a focused text field because its
        /// own elements were not visible — the normal case for a
        /// third-party keyboard extension, which runs out-of-process.
        public let detection: String
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        let client = try IOSDeviceController().client(udid: device.resolved)
        let state = try client.keyboardState()
        return ExecutionResult(
            visible: state.visible,
            owner: state.owner,
            top: state.frame?.y,
            detection: state.detection
        )
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        guard result.visible else { return .line("hidden") }
        // The top edge is the actionable number: anything below it is
        // occluded and a tap there hits the keyboard instead. It is
        // absent when the keyboard was inferred from focus alone, which
        // proves it is up but not where — say so rather than implying
        // the geometry is merely uninteresting.
        if let top = result.top {
            return .line("soft (occludes below y=\(Int(top)))")
        }
        if result.detection == "focus" {
            return .line("soft (bounds unknown — out-of-process keyboard extension)")
        }
        return .line("soft")
    }
}

/// `sim-use ios-device button` — hardware buttons.
public struct IOSDeviceButtonCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "button",
        abstract: "Press a hardware button (home, lock, volumeup, volumedown)."
    )

    @OptionGroup public var device: IOSDeviceOptions

    @Argument(help: "Button name: home, lock, volumeup, volumedown.")
    public var name: String

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {button}}` envelope.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public let button: String
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        let client = try IOSDeviceController().client(udid: device.resolved)
        try client.button(name.lowercased())
        return ExecutionResult(button: name.lowercased())
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line("Pressed \(result.button)")
    }
}
