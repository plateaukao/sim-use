// SPDX-License-Identifier: Apache-2.0
import Foundation
import UIKit
import XCTest

/// `/paste` — put text on the system pasteboard and, unless the caller
/// only wanted the clipboard set, deliver it into the focused field.
///
/// Two things differ from the Android bridge's `PasteHandler`:
///
///  1. **There is no `ACTION_PASTE`, and Cmd+V does not work either.**
///     Android can tell a specific node to paste; iOS has no equivalent
///     accessibility action reachable from outside the app. The obvious
///     substitute — a synthesized Cmd+V, which is what the Simulator
///     backend uses — **does not work on a real device**: synthesized
///     key events arrive as characters on the text-input stream and
///     never become the `UIKeyCommand` UIKit needs to run a paste. The
///     Simulator injects at the HID level, below that boundary, which is
///     why the same verb works there.
///
///     Measured on iOS 27 with the system keyboard *and* a third-party
///     IME, and with a synthesized long-press (no edit menu appears
///     either). So on device this endpoint reliably sets the pasteboard
///     and reports honestly whether delivery landed — it does not
///     pretend. `clipboard_only` is the primitive that always works.
///  2. **iOS 16+ may interpose an "Allow Paste?" alert.** Reading a
///     pasteboard the app did not write is a user-consent operation. The
///     alert belongs to SpringBoard, so it shows up in `describe-ui` and
///     the host's existing alert handling can dismiss it; we surface a
///     hint in the response rather than trying to tap it from here,
///     because auto-accepting a consent prompt on a real device with a
///     real pasteboard is not ours to decide.
final class PasteHandler {

    /// `XCUIKeyModifierFlags`, spelled out rather than kept as a lone
    /// magic constant.
    ///
    /// The first cut used `1 << 3` for Command, which is **Option**.
    /// Nothing errored: `Cmd+A` / `Cmd+V` went to the device as
    /// `Option+A` / `Option+V` and the field quietly filled with `å√`
    /// while `/paste` still reported success. Writing the whole set out
    /// makes the off-by-one-bit visible at the call site.
    private enum KeyModifier {
        static let capsLock: UInt = 1 << 0
        static let shift: UInt = 1 << 1
        static let control: UInt = 1 << 2
        static let option: UInt = 1 << 3
        static let command: UInt = 1 << 4
        static let function: UInt = 1 << 5
    }

    func paste(params: [String: String]) -> HTTPResponse {
        guard let encoded = params["base64_text"] else { return GestureHandler.badRequest("missing_base64_text") }
        guard
            let decoded = Data(base64Encoded: encoded),
            let text = String(data: decoded, encoding: .utf8)
        else {
            return GestureHandler.badRequest("invalid_base64")
        }

        UIPasteboard.general.string = text

        // `clipboard_only` stops here — useful when the caller wants to
        // stage content and drive the paste through the app's own UI.
        if params["clipboard_only"]?.lowercased() == "true" {
            return HTTPResponse(status: 200, json: Envelope.success(["pasted": false, "clipboard": true]))
        }

        let bundleID = params["bundle_id"] ?? SimUsePrivateAPI.activeForegroundBundleIDs().first
        let orientation = SimUsePrivateAPI.interfaceOrientation(forBundleID: bundleID)

        // `replace` mirrors the Android flag: select the field's
        // contents first so the paste overwrites instead of inserting at
        // the caret. Cmd+A is the same hardware-keyboard route as Cmd+V.
        if params["replace"]?.lowercased() == "true" {
            do {
                try SimUsePrivateAPI.pressKey("a", modifierFlags: KeyModifier.command, interfaceOrientation: orientation)
            } catch {
                return HTTPResponse(status: 500, json: Envelope.error(
                    code: "select_all_failed",
                    message: error.localizedDescription
                ))
            }
        }

        // Snapshot the field before the keystroke so we can tell whether
        // it actually landed. Without this the handler reports success
        // for a Cmd+V the system silently ignored — which, on a real
        // device, is every time.
        let before = focusedValue(bundleID: bundleID)

        do {
            try SimUsePrivateAPI.pressKey("v", modifierFlags: KeyModifier.command, interfaceOrientation: orientation)
        } catch {
            return HTTPResponse(status: 500, json: Envelope.error(
                code: "paste_failed",
                message: "\(error.localizedDescription). The clipboard was set, so the text can still be pasted manually."
            ))
        }

        // UIKit applies the paste asynchronously; give it a beat before
        // reading back, or a successful paste reads as a failed one.
        Thread.sleep(forTimeInterval: 0.4)
        let after = focusedValue(bundleID: bundleID)

        // `nil` on either side means we could not see the field at all
        // (no focused text input in the snapshot). Unverifiable is not
        // the same as failed, so report it as such rather than claiming
        // either outcome.
        guard let before, let after else {
            return HTTPResponse(status: 200, json: Envelope.success([
                "pasted": true,
                "verified": false,
                "clipboard": true,
                "hint": "Could not read the focused field to confirm the paste landed. Check with describe-ui.",
            ]))
        }

        guard after != before else {
            return HTTPResponse(status: 200, json: Envelope.success([
                "pasted": false,
                "verified": true,
                "clipboard": true,
                "reason": "keystroke_ignored",
                "hint": """
                    The text is on the device pasteboard, but iOS did not apply Cmd+V. \
                    Synthesized key events reach the text-input stream as characters; \
                    they do not become the UIKey command UIKit needs to run a paste. \
                    (The Simulator backend injects at the HID level, which is why the \
                    same verb works there.) Measured on iOS 27 with both the system \
                    keyboard and a third-party IME — it is not keyboard-specific. \
                    Paste manually, attach a hardware keyboard, or use `type` for text \
                    the keyboard can produce.
                    """,
            ]))
        }

        return HTTPResponse(status: 200, json: Envelope.success([
            "pasted": true,
            "verified": true,
            "clipboard": true,
        ]))
    }

    /// Current value of whatever holds keyboard focus, or nil when no
    /// focused text input is visible in the snapshot.
    private func focusedValue(bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        let app = XCUIApplication(bundleIdentifier: bundleID)
        guard let snapshot = try? app.snapshot() else { return nil }
        guard let focused = FocusedElement.find(in: snapshot) else { return nil }
        // An empty field legitimately has no `value`; map that to "" so
        // a paste into an empty field still registers as a change.
        return (focused.value as? String) ?? ""
    }
}
