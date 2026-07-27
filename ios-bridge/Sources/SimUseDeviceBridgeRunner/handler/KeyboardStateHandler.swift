// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest

/// `/keyboard/state` — is the on-screen keyboard up, and how much of the
/// screen does it cover.
///
/// Harder on a real device than the one-liner it looks like. The Android
/// bridge reads this straight off `AccessibilityWindowInfo` window
/// types; here there is no single authoritative source, because **a
/// third-party keyboard runs in its own extension process** and its view
/// hierarchy never appears in the foreground app's accessibility
/// snapshot. Measured on an iPhone 17 Pro with a third-party IME
/// (蝦米輸入法) active: the keyboard was plainly on screen, Spotlight was
/// foreground and focused, and neither Spotlight's nor SpringBoard's
/// tree contained a single `Keyboard` or `Key` element.
///
/// So detection is a ladder of four independent signals, reported back
/// as `detection` so a wrong answer is diagnosable without a rebuild:
///
///   1. `query`    — `XCUIApplication.keyboards`, XCTest's own query
///                   engine (what WebDriverAgent uses). Resolves hosted
///                   hierarchies that a flat snapshot walk can miss.
///   2. `snapshot` — a `Keyboard` element in the tree. The common case
///                   for Apple's in-process keyboard.
///   3. `keys`     — enough `Key` elements to be a keyboard whose
///                   container element didn't survive.
///   4. `focus`    — a focused text input. Orthogonal to all of the
///                   above: it says nothing about the keyboard's own
///                   elements, which is exactly why it catches the
///                   out-of-process-IME case the other three miss.
///
/// Only 1–3 can report a frame; `focus` proves the keyboard is up but
/// not where it is.
final class KeyboardStateHandler {

    /// Below this, stray `Key`-typed elements (a game's on-screen
    /// controls, a custom numeric pad) would read as a full keyboard.
    private static let minimumKeyCount = 5

    func state() -> HTTPResponse {
        var candidates = SimUsePrivateAPI.activeForegroundBundleIDs()
        if !candidates.contains(SnapshotHandler.springBoardBundleID) {
            candidates.append(SnapshotHandler.springBoardBundleID)
        }

        for bundleID in candidates {
            let app = XCUIApplication(bundleIdentifier: bundleID)
            // Not `== .runningForeground`: SpringBoard is commonly
            // reported as background while it still owns the keyboard,
            // and the earlier strict check is why the fallback never
            // got a chance to run.
            guard app.state == .runningForeground || app.state == .runningBackground else { continue }

            if let found = detect(in: app) {
                var payload: [String: Any] = [
                    "visible": true,
                    "owner": bundleID,
                    "detection": found.detection,
                ]
                if let frame = found.frame {
                    payload["frame"] = [
                        "x": frame.origin.x,
                        "y": frame.origin.y,
                        "width": frame.size.width,
                        "height": frame.size.height,
                    ]
                }
                return HTTPResponse(status: 200, json: Envelope.success(payload))
            }
        }

        return HTTPResponse(status: 200, json: Envelope.success([
            "visible": false,
            "detection": "none",
        ]))
    }

    private struct Detection {
        let detection: String
        let frame: CGRect?
    }

    private func detect(in app: XCUIApplication) -> Detection? {
        // 1. XCTest's query engine.
        let keyboards = app.keyboards
        if keyboards.count > 0 {
            let element = keyboards.firstMatch
            // `.frame` on a matched element is a live query; guard it
            // with `exists` so a keyboard that vanished between the
            // count and the read doesn't raise.
            if element.exists {
                let frame = element.frame
                return Detection(
                    detection: "query",
                    frame: frame.width > 0 && frame.height > 0 ? frame : nil
                )
            }
        }

        guard let snapshot = try? app.snapshot() else { return nil }

        // 2. A Keyboard element with real bounds. A dismissed keyboard
        //    often lingers in the tree with a zero or off-screen frame,
        //    so presence alone is not the signal.
        if let keyboard = Self.firstKeyboard(snapshot) {
            return Detection(detection: "snapshot", frame: keyboard.frame)
        }

        // 3. Loose keys without their container.
        let keyFrames = Self.keyFrames(snapshot)
        if keyFrames.count >= Self.minimumKeyCount {
            return Detection(detection: "keys", frame: Self.union(keyFrames))
        }

        // 4. Focused text input — the out-of-process-IME case.
        if let focused = FocusedElement.find(in: snapshot), FocusedElement.isTextInput(focused) {
            return Detection(detection: "focus", frame: nil)
        }

        return nil
    }

    private static func firstKeyboard(_ snapshot: XCUIElementSnapshot) -> XCUIElementSnapshot? {
        if snapshot.elementType == .keyboard, snapshot.frame.width > 0, snapshot.frame.height > 0 {
            return snapshot
        }
        for child in snapshot.children {
            if let match = firstKeyboard(child) { return match }
        }
        return nil
    }

    private static func keyFrames(_ snapshot: XCUIElementSnapshot) -> [CGRect] {
        var found: [CGRect] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .key, node.frame.width > 0, node.frame.height > 0 {
                found.append(node.frame)
            }
            node.children.forEach(walk)
        }
        walk(snapshot)
        return found
    }

    private static func union(_ frames: [CGRect]) -> CGRect? {
        guard var result = frames.first else { return nil }
        for frame in frames.dropFirst() { result = result.union(frame) }
        return result
    }
}
