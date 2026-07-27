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
        try Self.performPaste(
            udid: device.resolved,
            text: text,
            replace: replace,
            clipboardOnly: clipboardOnly
        )
    }

    /// Reusable device paste entry point; the top-level cross-platform
    /// `paste` forwards here so both surfaces share the verification
    /// contract below.
    public static func performPaste(
        udid: String,
        text: String,
        replace: Bool,
        clipboardOnly: Bool,
        controller: IOSDeviceController = IOSDeviceController()
    ) throws -> ExecutionResult {
        let client = try controller.client(udid: udid)
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

/// `sim-use ios-device gesture` — preset gesture patterns: single-finger
/// presets through `/swipe`, pinch / rotate through `/gesture`
/// multi-stroke dispatch. The stroke encoding is `GesturePresetStrokeEncoder`,
/// shared with the Android bridge — both accept byte-identical payloads.
public struct IOSDeviceGestureCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "gesture",
        abstract: "Perform a preset gesture pattern on a real iOS device.",
        discussion: """
        Same preset vocabulary as the Simulator and Android: scroll-*,
        swipe-from-*-edge, pinch-in / pinch-out, rotate-cw / rotate-ccw.

        Coordinates are in points, the same space `describe-ui` reports.
        Screen size defaults to the last `describe-ui` snapshot for this
        device (or a fresh one when none exists); pass --screen-width /
        --screen-height to override, e.g. after rotating the device
        without re-observing.
        """
    )

    @OptionGroup public var device: IOSDeviceOptions

    @Argument(help: "The gesture preset to perform.")
    public var preset: GesturePreset

    @Option(name: .customLong("screen-width"), help: "Screen width in points. Optional — defaults to the last describe-ui snapshot's screen size.")
    public var screenWidth: Double?

    @Option(name: .customLong("screen-height"), help: "Screen height in points. Optional — defaults to the last describe-ui snapshot's screen size.")
    public var screenHeight: Double?

    @Option(name: .customLong("duration"), help: "Duration of the gesture in seconds (uses preset default if not specified).")
    public var duration: Double?

    @Option(name: .customLong("scale"), help: "Pinch scale ratio (end radius / start radius). Defaults: 2.0 for pinch-out, 0.5 for pinch-in. Ignored for non-pinch presets.")
    public var scale: Double?

    @Option(name: .customLong("angle"), help: "Rotation sweep in degrees for rotate-cw / rotate-ccw. Default 90.0. Ignored for non-rotate presets.")
    public var angle: Double?

    @Option(name: .customLong("center-x"), help: "Pivot X for pinch / rotate presets (points). Defaults to screen center.")
    public var centerX: Double?

    @Option(name: .customLong("center-y"), help: "Pivot Y for pinch / rotate presets (points). Defaults to screen center.")
    public var centerY: Double?

    @Option(name: .customLong("radius"), help: "Start radius for pinch / rotate presets (points). Default 80.")
    public var radius: Double?

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {}}` envelope on success.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public init() {}
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func validate() throws {
        // Same rules as the other backends' gesture verbs — `--scale`
        // only on pinch presets, `--angle` only on rotate, range checks
        // on the geometry knobs. `--delta` / `--steps` / `--step-ms`
        // are HID-specific and not exposed here.
        try GesturePreset.validateOptions(
            preset: preset,
            screenWidth: screenWidth, screenHeight: screenHeight,
            duration: duration, delta: nil,
            scale: scale, angle: angle,
            centerX: centerX, centerY: centerY, radius: radius,
            steps: 1, stepMs: nil,
            preDelay: nil, postDelay: nil
        )
    }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        try Self.performGesture(
            udid: device.resolved,
            preset: preset,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            duration: duration,
            scale: scale,
            angle: angle,
            centerX: centerX,
            centerY: centerY,
            radius: radius
        )
        return ExecutionResult()
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(stderr: "gesture \(preset.rawValue)\n")
    }

    /// Reusable device gesture entry point; the top-level cross-platform
    /// `Gesture` forwards here for real-device UDIDs. Symmetric to
    /// `AndroidGestureCommand.performGesture`.
    ///
    /// Screen-size resolution order:
    ///   1. explicit `screenWidth` / `screenHeight` arguments
    ///   2. the outline cache written by the last `describe-ui` — free,
    ///      and fresh in the observe → act cycle every skill teaches
    ///   3. a fresh tree snapshot (2–4 s on device) when no cache exists
    /// We do NOT fall back to the Simulator's 390×844 default — a wrong
    /// pinch center on a real phone is not recoverable the way it is on
    /// a simulator.
    ///
    /// No display-bounds assertion here, deliberately: Android's
    /// framework rejects out-of-bounds strokes so that backend
    /// pre-flights them; iOS clamps silently. Each backend keeps its
    /// own policy (see `GesturePresetStrokeEncoder`).
    public static func performGesture(
        udid: String,
        preset: GesturePreset,
        screenWidth: Double?,
        screenHeight: Double?,
        duration: Double?,
        scale: Double? = nil,
        angle: Double? = nil,
        centerX: Double? = nil,
        centerY: Double? = nil,
        radius: Double? = nil,
        controller: IOSDeviceController = IOSDeviceController()
    ) throws {
        let client = try controller.client(udid: udid)

        let width: Double
        let height: Double
        if let screenWidth, let screenHeight {
            width = screenWidth
            height = screenHeight
        } else {
            (width, height) = try Self.detectScreenSize(udid: udid, client: client)
        }

        let gestureDuration = duration ?? preset.recommendedDuration(angle: angle)
        let durationMs = max(1, Int((gestureDuration * 1000).rounded()))

        if preset.isMultiTouch {
            let presetStrokes = preset.strokes(
                screenWidth: width, screenHeight: height,
                scale: scale, angle: angle,
                centerX: centerX, centerY: centerY,
                radius: radius
            )
            try client.gesture(strokes: GesturePresetStrokeEncoder.strokes(presetStrokes, durationMilliseconds: durationMs))
        } else {
            let coords = preset.coordinates(screenWidth: width, screenHeight: height)
            try client.swipe(
                startX: coords.startX, startY: coords.startY,
                endX: coords.endX, endY: coords.endY,
                durationMilliseconds: durationMs
            )
        }
    }

    static func detectScreenSize(udid: String, client: IOSDeviceBridgeClient) throws -> (width: Double, height: Double) {
        if
            let cached = try? OutlineCache.read(udid: udid),
            cached.screen.width > 0, cached.screen.height > 0
        {
            return (Double(cached.screen.width), Double(cached.screen.height))
        }
        if let display = try client.fetchTree(filter: true).display {
            return display
        }
        throw CLIError(errorDescription: """
            Could not determine the device screen size (no cached outline, and the \
            bridge snapshot reported no display). Run `describe-ui` first or pass \
            --screen-width / --screen-height.
            """)
    }
}

/// `sim-use ios-device touch` — the atomic down/up form only. The
/// split form (`--down` alone now, `--up` in a later invocation) is
/// impossible here for the same reason it is on Android: the XCUITest
/// synthesized-event API delivers a whole gesture atomically and has
/// no way to hold a touch open across calls. Rejected with a redirect
/// to the atomic form, mirroring `AndroidTouchCommand`.
public struct IOSDeviceTouchCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "touch",
        abstract: "Perform an atomic touch down+up at specific coordinates on a real iOS device."
    )

    @OptionGroup public var device: IOSDeviceOptions

    @Option(name: [.customShort("x"), .customLong("x")], help: "The X coordinate of the touch point (points).")
    public var pointX: Double

    @Option(name: [.customShort("y"), .customLong("y")], help: "The Y coordinate of the touch point (points).")
    public var pointY: Double

    @Flag(name: .customLong("down"), help: "Perform touch down event.")
    public var touchDown: Bool = false

    @Flag(name: .customLong("up"), help: "Perform touch up event.")
    public var touchUp: Bool = false

    @Option(name: .customLong("delay"), help: "Hold between down and up in seconds.")
    public var delay: Double?

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {}}` envelope on success.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public init() {}
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func validate() throws {
        guard pointX >= 0, pointY >= 0 else {
            throw ValidationError("Coordinates must be non-negative values.")
        }
        guard touchDown && touchUp else {
            throw ValidationError(Self.splitFormRedirect(x: pointX, y: pointY, udid: device.resolved))
        }
        if let delay {
            guard delay >= 0 else {
                throw ValidationError("Delay must be non-negative.")
            }
            guard delay <= 10.0 else {
                throw ValidationError("Delay must not exceed 10 seconds.")
            }
        }
    }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        try Self.performTouch(udid: device.resolved, x: pointX, y: pointY, delay: delay)
        return ExecutionResult()
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        .line("✓ Touch at (\(Int(pointX.rounded())), \(Int(pointY.rounded()))) completed successfully")
    }

    /// Reusable device touch entry point; the top-level cross-platform
    /// `Touch` forwards here. A `delay` of nil is a plain tap — the
    /// bridge floors the hold at 20 ms so gesture recognisers never see
    /// a zero-length contact.
    public static func performTouch(
        udid: String,
        x: Double,
        y: Double,
        delay: Double?,
        controller: IOSDeviceController = IOSDeviceController()
    ) throws {
        let client = try controller.client(udid: udid)
        try client.tap(x: x, y: y, durationMilliseconds: delay.map { max(1, Int(($0 * 1000).rounded())) })
    }

    /// Redirect surfaced when the user passes only `--down` or only
    /// `--up`. Public so the cross-platform forwarder emits the same
    /// text. Mirrors `AndroidTouchCommand.splitFormRedirect`.
    public static func splitFormRedirect(x: Double, y: Double, udid: String) -> String {
        let xi = Int(x.rounded())
        let yi = Int(y.rounded())
        return "Split touch form (--down or --up alone) is not supported on real iOS devices — "
            + "the on-device synthesized-event API delivers a whole gesture atomically and "
            + "cannot hold a touch open across invocations. "
            + "Use the atomic form `sim-use touch --x \(xi) --y \(yi) "
            + "--down --up --delay <seconds> --device \(udid)` instead, "
            + "or `sim-use tap` / `sim-use long-press` for the common cases."
    }
}

/// `sim-use ios-device multi-touch` — two parallel strokes through the
/// bridge's `/gesture`, with explicit start / end positions per finger.
/// Mirrors the Android verb's surface so the top-level cross-platform
/// `multi-touch` forwarder routes here with identical flag shapes.
public struct IOSDeviceMultiTouchCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "multi-touch",
        abstract: "Dispatch a two-finger gesture with explicit start / end positions for each finger on a real iOS device."
    )

    @OptionGroup public var device: IOSDeviceOptions

    @Option(name: .customLong("x1"), help: "First finger start X (points).")
    public var x1: Double

    @Option(name: .customLong("y1"), help: "First finger start Y (points).")
    public var y1: Double

    @Option(name: .customLong("x2"), help: "Second finger start X (points).")
    public var x2: Double

    @Option(name: .customLong("y2"), help: "Second finger start Y (points).")
    public var y2: Double

    @Option(name: .customLong("x1-end"), help: "First finger end X (points).")
    public var x1End: Double

    @Option(name: .customLong("y1-end"), help: "First finger end Y (points).")
    public var y1End: Double

    @Option(name: .customLong("x2-end"), help: "Second finger end X (points).")
    public var x2End: Double

    @Option(name: .customLong("y2-end"), help: "Second finger end Y (points).")
    public var y2End: Double

    @Option(name: .customLong("duration"), help: "Gesture duration in seconds. Default 0.5.")
    public var duration: Double = 0.5

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {}}` envelope on success.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public init() {}
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    public func validate() throws {
        guard duration > 0 && duration <= 10.0 else {
            throw ValidationError("--duration must be between 0 and 10 seconds.")
        }
    }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        try Self.performMultiTouch(
            udid: device.resolved,
            startP1: (x1, y1),
            startP2: (x2, y2),
            endP1: (x1End, y1End),
            endP2: (x2End, y2End),
            duration: duration
        )
        return ExecutionResult()
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(stderr: "multi-touch (\(x1),\(y1))/(\(x2),\(y2)) → (\(x1End),\(y1End))/(\(x2End),\(y2End))\n")
    }

    /// Reusable device multi-touch entry point; the top-level
    /// cross-platform `MultiTouch` forwards here. Symmetric to
    /// `AndroidMultiTouchCommand.performMultiTouch` — same two-stroke
    /// shape, no display-bounds pre-flight (iOS clamps silently; see
    /// `IOSDeviceGestureCommand.performGesture`).
    public static func performMultiTouch(
        udid: String,
        startP1: (x: Double, y: Double),
        startP2: (x: Double, y: Double),
        endP1: (x: Double, y: Double),
        endP2: (x: Double, y: Double),
        duration: Double,
        controller: IOSDeviceController = IOSDeviceController()
    ) throws {
        let client = try controller.client(udid: udid)
        let durationMs = max(1, Int((duration * 1000).rounded()))
        try client.gesture(strokes: [
            .linear(
                startX: startP1.x, startY: startP1.y,
                endX: endP1.x, endY: endP1.y,
                startTime: 0, duration: durationMs
            ),
            .linear(
                startX: startP2.x, startY: startP2.y,
                endX: endP2.x, endY: endP2.y,
                startTime: 0, duration: durationMs
            ),
        ])
    }

    /// Two-finger tap / long-press: both fingers hold at their start
    /// positions. `start == end` with a real duration is the same
    /// pattern every backend uses to surface a hold to recognisers.
    /// Used by the top-level `tap --fingers 2` / `long-press
    /// --fingers 2` device paths.
    public static func performTwoFingerHold(
        udid: String,
        finger1: (x: Double, y: Double),
        finger2: (x: Double, y: Double),
        duration: Double?,
        controller: IOSDeviceController = IOSDeviceController()
    ) throws {
        try performMultiTouch(
            udid: udid,
            startP1: finger1, startP2: finger2,
            endP1: finger1, endP2: finger2,
            duration: duration ?? 0.05,
            controller: controller
        )
    }
}
