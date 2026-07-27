// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest

/// Wire schema for one accessibility element.
///
/// This deliberately reproduces the shape that idb's
/// `accessibilityElements(withNestedFormat:)` returns for the iOS
/// Simulator, because the host decodes both with the **same** type
/// (`AccessibilityElement` in `Sources/iOSSimBackend/A11y/`). Matching it
/// means `OutlineFormatter`, `ListDetector`, `AccessibilityTargetResolver`
/// and every `@N` / `--label` / `#id` selector work on a real iPhone
/// without a line of new normalizer code, and the outline a user sees is
/// identical between simulator and device.
///
/// Field-for-field correspondence with `XCUIElementSnapshot`:
///
/// | wire         | snapshot            |
/// |--------------|---------------------|
/// | `type`       | `elementType`       |
/// | `frame`      | `frame`             |
/// | `enabled`    | `isEnabled`         |
/// | `AXLabel`    | `label` (or `title`)|
/// | `AXUniqueId` | `identifier`        |
/// | `AXValue`    | `value`             |
/// | `children`   | `children`          |
struct AXNode {
    let type: String
    let frame: CGRect
    let enabled: Bool
    let label: String?
    let uniqueID: String?
    let value: String?
    let children: [AXNode]

    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "type": type,
            "enabled": enabled,
            "frame": [
                "x": frame.origin.x,
                "y": frame.origin.y,
                "width": frame.size.width,
                "height": frame.size.height,
            ],
            "children": children.map { $0.toJSON() },
        ]
        // Absent rather than empty-string, so the host can tell "the
        // element has no label" from "the label is the empty string" —
        // `AccessibilityElement` models all three as `String?`.
        if let label { json["AXLabel"] = label }
        if let uniqueID { json["AXUniqueId"] = uniqueID }
        if let value { json["AXValue"] = value }
        return json
    }
}

extension AXNode {
    /// Builds a node tree from an `XCUIElementSnapshot`.
    ///
    /// - Parameter filterInvisible: drops leaf elements with an empty
    ///   frame. Those are overwhelmingly layout scaffolding that the
    ///   outline would render as noise; a zero-frame element with
    ///   children is kept because its descendants may still be on
    ///   screen.
    static func from(snapshot: XCUIElementSnapshot, filterInvisible: Bool) -> AXNode? {
        let children = snapshot.children.compactMap {
            AXNode.from(snapshot: $0, filterInvisible: filterInvisible)
        }

        let frame = snapshot.frame
        if filterInvisible, children.isEmpty, frame.width <= 0 || frame.height <= 0 {
            return nil
        }

        // `label` is the accessibility label; `title` is the AppKit-ish
        // window/menu title that iOS controls rarely set. Prefer label
        // and fall back so a titled-but-unlabelled element still names
        // itself in the outline.
        let label = Self.nonEmpty(snapshot.label) ?? Self.nonEmpty(snapshot.title)

        return AXNode(
            type: ElementTypeName.of(snapshot.elementType),
            frame: frame,
            enabled: snapshot.isEnabled,
            label: label,
            uniqueID: Self.nonEmpty(snapshot.identifier),
            value: Self.stringify(snapshot.value),
            children: children
        )
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// `XCUIElementSnapshot.value` is `Any?`: a String for text fields,
    /// an NSNumber for switches and segmented controls, occasionally a
    /// Bool. The host's `AccessibilityElement` already tolerates all of
    /// those on decode, but stringifying here keeps the wire uniform.
    private static func stringify(_ value: Any?) -> String? {
        switch value {
        case nil: return nil
        case let text as String: return text.isEmpty ? nil : text
        case let flag as Bool: return flag ? "1" : "0"
        case let number as NSNumber: return number.stringValue
        default: return String(describing: value!)
        }
    }
}

/// `XCUIElement.ElementType` → the role strings the host's element
/// vocabulary (`SimUseCore/ElementType.swift`) and outline renderer
/// already speak. The table is written against the enum cases rather
/// than raw integers so a case rename fails the build instead of
/// silently mislabelling every element of that kind.
enum ElementTypeName {
    static func of(_ type: XCUIElement.ElementType) -> String {
        table[type] ?? "Other"
    }

    private static let table: [XCUIElement.ElementType: String] = [
        .any: "Any",
        .other: "Other",
        .application: "Application",
        .group: "Group",
        .window: "Window",
        .sheet: "Sheet",
        .drawer: "Drawer",
        .alert: "Alert",
        .dialog: "Dialog",
        .button: "Button",
        .radioButton: "RadioButton",
        .radioGroup: "RadioGroup",
        .checkBox: "CheckBox",
        .disclosureTriangle: "DisclosureTriangle",
        .popUpButton: "PopUpButton",
        .comboBox: "ComboBox",
        .menuButton: "MenuButton",
        .toolbarButton: "ToolbarButton",
        .popover: "Popover",
        .keyboard: "Keyboard",
        .key: "Key",
        .navigationBar: "NavigationBar",
        .tabBar: "TabBar",
        .tabGroup: "TabGroup",
        .toolbar: "Toolbar",
        .statusBar: "StatusBar",
        .table: "Table",
        .tableRow: "TableRow",
        .tableColumn: "TableColumn",
        .outline: "Outline",
        .outlineRow: "OutlineRow",
        .browser: "Browser",
        .collectionView: "CollectionView",
        .slider: "Slider",
        .pageIndicator: "PageIndicator",
        .progressIndicator: "ProgressIndicator",
        .activityIndicator: "ActivityIndicator",
        .segmentedControl: "SegmentedControl",
        .picker: "Picker",
        .pickerWheel: "PickerWheel",
        .switch: "Switch",
        .toggle: "Toggle",
        .link: "Link",
        .image: "Image",
        .icon: "Icon",
        .searchField: "SearchField",
        .scrollView: "ScrollView",
        .scrollBar: "ScrollBar",
        .staticText: "StaticText",
        .textField: "TextField",
        .secureTextField: "SecureTextField",
        .datePicker: "DatePicker",
        .textView: "TextView",
        .menu: "Menu",
        .menuItem: "MenuItem",
        .menuBar: "MenuBar",
        .menuBarItem: "MenuBarItem",
        .map: "Map",
        .webView: "WebView",
        .incrementArrow: "IncrementArrow",
        .decrementArrow: "DecrementArrow",
        .timeline: "Timeline",
        .ratingIndicator: "RatingIndicator",
        .valueIndicator: "ValueIndicator",
        .splitGroup: "SplitGroup",
        .splitter: "Splitter",
        .relevanceIndicator: "RelevanceIndicator",
        .colorWell: "ColorWell",
        .helpTag: "HelpTag",
        .matte: "Matte",
        .dockItem: "DockItem",
        .ruler: "Ruler",
        .rulerMarker: "RulerMarker",
        .grid: "Grid",
        .levelIndicator: "LevelIndicator",
        .cell: "Cell",
        .layoutArea: "LayoutArea",
        .layoutItem: "LayoutItem",
        .handle: "Handle",
        .stepper: "Stepper",
        .tab: "Tab",
        .touchBar: "TouchBar",
        .statusItem: "StatusItem",
    ]
}
