// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest

/// Finds the element that currently holds keyboard focus.
///
/// Shared by `InputHandler` (which needs the field's length to clear it)
/// and `KeyboardStateHandler` (which uses focus as an independent
/// keyboard-visibility signal). Kept in one place because both callers
/// depend on the same undocumented attribute, and a future Xcode that
/// drops it should break exactly one lookup.
enum FocusedElement {

    /// `hasKeyboardFocus` is populated by XCTest but not published on
    /// the `XCUIElementSnapshot` protocol, so it is read by key. A
    /// future SDK that removes it yields nil, and callers degrade
    /// rather than crash.
    static func find(in snapshot: XCUIElementSnapshot) -> XCUIElementSnapshot? {
        if let object = snapshot as? NSObject,
           let focused = object.value(forKey: "hasKeyboardFocus") as? Bool,
           focused {
            return snapshot
        }
        for child in snapshot.children {
            if let match = find(in: child) { return match }
        }
        return nil
    }

    /// Element types that imply a keyboard when focused. A focused
    /// button or cell means nothing; a focused text field means the
    /// keyboard is up (or is about to be).
    static func isTextInput(_ snapshot: XCUIElementSnapshot) -> Bool {
        switch snapshot.elementType {
        case .textField, .secureTextField, .textView, .searchField:
            return true
        default:
            return false
        }
    }
}
