// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Verbs the real-device backend does not implement yet.
///
/// Kept as one explicit list rather than letting each forwarder invent
/// its own wording, so the gap is visible in one place and the message
/// always tells the user what *does* work instead. Every entry here is
/// a deliberate scope boundary, not an oversight — see the notes.
public enum IOSDeviceVerbSupport {

    /// verb → what to suggest instead.
    static let unimplemented: [String: String] = [
        // Needs the device screen-recording service, a different code
        // path from anything the bridge does today.
        "record-video": "video recording is not available on real devices yet; use `screenshot`",
    ]

    public static func unsupported(_ verb: String) -> CLIError {
        let detail = unimplemented[verb] ?? "\(verb) is not supported on real iOS devices yet"
        return CLIError(errorDescription: """
            `\(verb)` is not available on real iOS devices: \(detail).

            Supported today: describe-ui, tap, long-press, swipe, gesture, \
            multi-touch, touch (atomic form), type, paste, screenshot, \
            keyboard-state, button.
            """)
    }
}
