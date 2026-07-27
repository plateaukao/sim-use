// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Wire-contract constants for the on-device bridge.
///
/// `protocolVersion` is an independent lineage from the Android bridge's
/// `BuildConfig.PROTOCOL_VERSION`: the envelope is shared but
/// `/a11y_tree_full` returns an iOS accessibility tree, not an Android
/// one, so the two numbers can never be compared. Bump this only on a
/// breaking wire change, and bump
/// `IOSDeviceBridgeClient.expectedProtocolVersion` (Swift host side) in
/// the same commit.
///
/// `version` mirrors `MARKETING_VERSION` in `project.yml`; the host
/// compares it against its own release version to catch a stale runner
/// left installed from an older sim-use.
enum BridgeVersion {
    static let protocolVersion = 1

    static var version: String {
        // Info.plist is templated from `MARKETING_VERSION`, so this stays
        // in lockstep with project.yml without a second literal to keep
        // in sync.
        (Bundle(for: BridgeMarker.self).infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}

/// Anchor class used to resolve the runner's own bundle. `Bundle.main`
/// inside an XCTest bundle is the generated `*-Runner.app`, whose
/// Info.plist carries Xcode's version, not ours.
final class BridgeMarker {}
