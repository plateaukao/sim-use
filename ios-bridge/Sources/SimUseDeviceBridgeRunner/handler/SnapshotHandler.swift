// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest

/// `/a11y_tree_full` — the device counterpart of the Android bridge's
/// `TreeHandler`.
///
/// `result` is an **array** of application trees, front-most first,
/// which is exactly the shape idb hands back for the Simulator. The
/// host's `OutlineFormatter.render(tree:)` picks the first
/// `Application` element as the root, so ordering is the contract:
/// whatever is on top must come first. When a system permission alert
/// is up, SpringBoard is front-most and becomes the root — the same
/// behaviour the Simulator path already has, which is what makes the
/// existing `App: SpringBoard` alert classification work unchanged on
/// device.
final class SnapshotHandler {

    func tree(params: [String: String]) -> HTTPResponse {
        let filter = params["filter"]?.lowercased() == "true"
        let bundleIDs = resolveTargets(explicit: params["bundle_id"])

        guard !bundleIDs.isEmpty else {
            return HTTPResponse(status: 503, json: Envelope.error(
                code: "no_foreground_app",
                message: """
                    Could not determine the foreground application. \
                    \(SimUsePrivateAPI.unavailableReason ?? "activeForegroundApplications returned nothing"). \
                    Pass ?bundle_id=<id> to snapshot a specific app.
                    """
            ))
        }

        var roots: [[String: Any]] = []
        var failures: [String] = []
        var primaryFrame: CGRect = .zero
        var primaryBundleID: String?
        var primaryLabel: String?

        for bundleID in bundleIDs {
            let app = XCUIApplication(bundleIdentifier: bundleID)
            // `.snapshot()` on a not-running app throws rather than
            // returning an empty tree. A stale entry in the foreground
            // list is normal during an app switch, so record and move on
            // instead of failing the whole request.
            guard app.state == .runningForeground || app.state == .runningBackground else {
                failures.append("\(bundleID): state=\(app.state.rawValue)")
                continue
            }
            do {
                let snapshot = try app.snapshot()
                guard let node = AXNode.from(snapshot: snapshot, filterInvisible: filter) else {
                    failures.append("\(bundleID): snapshot filtered to nothing")
                    continue
                }
                if primaryBundleID == nil {
                    primaryBundleID = bundleID
                    primaryFrame = node.frame
                    primaryLabel = node.label
                }
                roots.append(node.toJSON())
            } catch {
                failures.append("\(bundleID): \(error.localizedDescription)")
            }
        }

        guard !roots.isEmpty else {
            return HTTPResponse(status: 500, json: Envelope.error(
                code: "tree_build_failed",
                message: "No application produced a snapshot. Tried: \(failures.joined(separator: "; "))"
            ))
        }

        var extra: [String: Any] = [
            "display": ["width": primaryFrame.width, "height": primaryFrame.height],
        ]
        // The host uses `app.bundle_id` for `ForegroundLabel.reconcile`,
        // which on the Simulator path is resolved out-of-band from the
        // AX root's pid. On device we know it first-hand, so the header
        // can never disagree with what is actually on screen.
        var app: [String: Any] = [:]
        if let primaryBundleID { app["bundle_id"] = primaryBundleID }
        if let primaryLabel { app["name"] = primaryLabel }
        if !app.isEmpty { extra["app"] = app }
        if !failures.isEmpty { extra["skipped"] = failures }

        return HTTPResponse(status: 200, json: Envelope.success(roots, extra: extra))
    }

    /// Foreground apps, front-most first, plus SpringBoard as a
    /// last-resort so a request never comes back empty on a device
    /// sitting at the home screen.
    private func resolveTargets(explicit: String?) -> [String] {
        if let explicit, !explicit.isEmpty {
            return [explicit]
        }
        var ids = SimUsePrivateAPI.activeForegroundBundleIDs()
        if ids.isEmpty {
            ids = [Self.springBoardBundleID]
        }
        return ids
    }

    static let springBoardBundleID = "com.apple.springboard"
}
