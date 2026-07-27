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
        // The bridge's /gesture endpoint exists and works; what is
        // missing is the host-side translation of the preset vocabulary
        // (pinch/rotate/zoom) into strokes for this backend.
        "gesture": "multi-stroke gestures are not wired up for real devices yet; use `swipe` for single-finger drags",
        "multi-touch": "multi-touch is not wired up for real devices yet; use `swipe` for single-finger drags",
        // `touch` exposes raw down/move/up phases, which the bridge's
        // one-shot event model cannot hold open across CLI invocations.
        "touch": "raw touch phases are not available on real devices — the synthesized-event API delivers a whole gesture at once; use `tap`, `long-press`, or `swipe`",
        // Needs the device screen-recording service, a different code
        // path from anything the bridge does today.
        "record-video": "video recording is not available on real devices yet; use `screenshot`",
    ]

    public static func unsupported(_ verb: String) -> CLIError {
        let detail = unimplemented[verb] ?? "\(verb) is not supported on real iOS devices yet"
        return CLIError(errorDescription: """
            `\(verb)` is not available on real iOS devices: \(detail).

            Supported today: describe-ui, tap, long-press, swipe, type, paste, \
            screenshot, keyboard-state, button.
            """)
    }
}
