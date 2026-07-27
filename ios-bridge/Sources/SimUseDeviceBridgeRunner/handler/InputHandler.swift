// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest

/// `/keyboard/input`, `/keyboard/key`, `/button` — the device
/// counterpart of the Android bridge's `InputHandler`.
///
/// Text goes through `XCPointerEventPath`'s text-input path rather than
/// `XCUIElement.typeText`, so the caller does not need an element
/// reference and the bridge does not have to guess which field to type
/// into: whatever holds keyboard focus receives the text, exactly like a
/// physical keyboard.
final class InputHandler {

    /// Characters per second handed to the synthesizer. The XCTest
    /// default (which WebDriverAgent also uses) drops characters on
    /// SwiftUI `TextField`s under heavy layout; 60 is comfortably fast
    /// and has not lost input in testing.
    private static let typingSpeed: UInt = 60

    /// `XCUIKeyboardKey.delete` is a backspace, not a forward delete.
    private static let backspace = "\u{8}"

    /// Ceiling on the synthetic backspaces `clear=true` will send when
    /// the focused field's length cannot be read. Long enough to empty a
    /// realistic form field, short enough not to chew through the rest
    /// of the screen's text if focus is somewhere unexpected.
    private static let maxBlindClearDeletes = 128

    func input(params: [String: String]) -> HTTPResponse {
        guard let encoded = params["base64_text"] else { return GestureHandler.badRequest("missing_base64_text") }
        guard
            let decoded = Data(base64Encoded: encoded),
            let text = String(data: decoded, encoding: .utf8)
        else {
            return GestureHandler.badRequest("invalid_base64")
        }
        // Matches the Android bridge: `clear` defaults to true, so
        // `type` replaces rather than appends unless told otherwise.
        let clear = params["clear"]?.lowercased() != "false"

        let bundleID = params["bundle_id"] ?? SimUsePrivateAPI.activeForegroundBundleIDs().first
        let orientation = SimUsePrivateAPI.interfaceOrientation(forBundleID: bundleID)

        var clearedCleanly = true
        if clear {
            if let clearError = clearFocusedField(bundleID: bundleID, orientation: orientation) {
                return clearError
            }
            // A field that still has content after two passes did not
            // clear; say so instead of letting the caller believe the
            // text that follows replaced it.
            clearedCleanly = (focusedValueLength(bundleID: bundleID) ?? 0) == 0
        }

        guard !text.isEmpty else {
            return HTTPResponse(status: 200, json: Envelope.success(["cleared": clearedCleanly]))
        }
        do {
            try SimUsePrivateAPI.typeText(text, typingSpeed: Self.typingSpeed, interfaceOrientation: orientation)
            return HTTPResponse(status: 200, json: Envelope.success(["cleared": clearedCleanly]))
        } catch {
            return HTTPResponse(status: 500, json: Envelope.error(
                code: "type_failed",
                message: "\(error.localizedDescription). Tap a text field first — synthesized text goes to whatever holds keyboard focus, and nothing does if the keyboard is not up."
            ))
        }
    }

    /// Named keys rather than Android's numeric keycodes: iOS has no
    /// `KeyEvent` constant space, and a name (`return`, `delete`) is
    /// what the CLI already speaks on the Simulator side.
    func key(params: [String: String]) -> HTTPResponse {
        guard let name = params["key"]?.lowercased(), !name.isEmpty else {
            return GestureHandler.badRequest("missing_key")
        }
        guard let sequence = Self.namedKeys[name] else {
            return HTTPResponse(status: 400, json: Envelope.error(
                code: "unsupported_key",
                message: "Unknown key '\(name)'. Supported: \(Self.namedKeys.keys.sorted().joined(separator: ", ")). Use /keyboard/input for arbitrary text."
            ))
        }
        let bundleID = params["bundle_id"] ?? SimUsePrivateAPI.activeForegroundBundleIDs().first
        let orientation = SimUsePrivateAPI.interfaceOrientation(forBundleID: bundleID)
        do {
            try SimUsePrivateAPI.typeText(sequence, typingSpeed: Self.typingSpeed, interfaceOrientation: orientation)
            return HTTPResponse(status: 200, json: Envelope.success())
        } catch {
            return HTTPResponse(status: 500, json: Envelope.error(code: "key_failed", message: error.localizedDescription))
        }
    }

    /// Hardware buttons. `home` and the volume pair are public
    /// `XCUIDevice.press(_:)` cases; `lock` is not, so it routes through
    /// the private shim.
    func button(params: [String: String]) -> HTTPResponse {
        guard let name = params["name"]?.lowercased(), !name.isEmpty else {
            return GestureHandler.badRequest("missing_name")
        }
        switch name {
        case "home":
            XCUIDevice.shared.press(.home)
        case "volumeup", "volumedown":
            // The volume cases are marked unavailable when building
            // against the Simulator SDK. The runner only ever executes
            // on a real device, but keeping it compilable for the
            // Simulator gives CI a signing-free compile check of every
            // other handler — worth one #if.
            #if targetEnvironment(simulator)
            return HTTPResponse(status: 501, json: Envelope.error(
                code: "unsupported_button",
                message: "Volume buttons are not available in the Simulator."
            ))
            #else
            XCUIDevice.shared.press(name == "volumeup" ? .volumeUp : .volumeDown)
            #endif
        case "lock", "power", "side":
            do {
                try SimUsePrivateAPI.pressLockButton()
            } catch {
                return HTTPResponse(status: 500, json: Envelope.error(code: "button_failed", message: error.localizedDescription))
            }
        default:
            return HTTPResponse(status: 400, json: Envelope.error(
                code: "unsupported_button",
                message: "Unknown button '\(name)'. Supported: home, lock, volumeup, volumedown."
            ))
        }
        return HTTPResponse(status: 200, json: Envelope.success())
    }

    // MARK: - Clear

    /// Empties the focused text field by sending as many backspaces as
    /// it has characters.
    ///
    /// There is no "select all and delete" primitive reachable without
    /// an `XCUIElement` reference, and the length has to come from
    /// somewhere: we read the focused element out of the app's snapshot.
    /// When the snapshot cannot identify a focused field (SwiftUI
    /// sometimes reports focus on an ancestor), fall back to a bounded
    /// blind run — losing a few keystrokes into an empty field is
    /// harmless, whereas leaving stale text behind silently corrupts the
    /// value the caller asked for.
    private func clearFocusedField(bundleID: String?, orientation: Int) -> HTTPResponse? {
        // `nil` means "could not read the field", which is NOT the same
        // as "the field is empty". Treating the two alike is how `type
        // --clear` came to report "field cleared first" and then append:
        // an unreadable value yielded a length of 0, so zero backspaces
        // were sent. Unknown now falls through to the bounded blind run.
        let count = focusedValueLength(bundleID: bundleID) ?? Self.maxBlindClearDeletes
        guard count > 0 else { return nil }

        if let failure = sendDeletes(count, orientation: orientation) { return failure }

        // Verify, and retry once. The length we computed can be short
        // when the field's accessibility value lags its contents, and a
        // partial clear is worse than none: the caller believes it
        // replaced the text when it actually prefixed it.
        if let remaining = focusedValueLength(bundleID: bundleID), remaining > 0 {
            if let failure = sendDeletes(min(remaining, Self.maxBlindClearDeletes), orientation: orientation) {
                return failure
            }
        }
        return nil
    }

    private func sendDeletes(_ count: Int, orientation: Int) -> HTTPResponse? {
        guard count > 0 else { return nil }
        do {
            try SimUsePrivateAPI.typeText(
                String(repeating: Self.backspace, count: count),
                typingSpeed: Self.typingSpeed,
                interfaceOrientation: orientation
            )
            return nil
        } catch {
            return HTTPResponse(status: 500, json: Envelope.error(
                code: "clear_failed",
                message: error.localizedDescription
            ))
        }
    }

    /// Character count of the focused field, or `nil` when it cannot be
    /// determined. Only returns 0 for a field we positively read as
    /// empty — see `clearFocusedField` for why the distinction matters.
    private func focusedValueLength(bundleID: String?) -> Int? {
        guard let bundleID else { return nil }
        let app = XCUIApplication(bundleIdentifier: bundleID)
        guard let snapshot = try? app.snapshot() else { return nil }
        guard let focused = FocusedElement.find(in: snapshot) else { return nil }
        if let value = focused.value as? String { return value.count }
        // Some fields expose their contents only as the label, and a
        // placeholder-only field reports neither — hence nil, not 0.
        if let label = focused.label as String?, !label.isEmpty, label != focused.placeholderValue {
            return label.count
        }
        return nil
    }

    /// Control characters the text-input path understands. These are the
    /// `XCUIKeyboardKey` raw values; spelling them out keeps the table
    /// readable and avoids depending on the constants being available on
    /// every SDK.
    private static let namedKeys: [String: String] = [
        "return": "\r",
        "enter": "\r",
        "newline": "\n",
        "tab": "\t",
        "delete": "\u{8}",
        "backspace": "\u{8}",
        "escape": "\u{1B}",
        "space": " ",
        "up": "\u{F700}",
        "down": "\u{F701}",
        "left": "\u{F702}",
        "right": "\u{F703}",
    ]
}
