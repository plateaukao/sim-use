// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Locates the `ios-bridge/` Xcode project that gets built into the
/// on-device runner.
///
/// The Android bridge ships as a prebuilt, debug-signed APK because any
/// Android device will install one. iOS cannot work that way: a test
/// runner has to be signed by a team the target device trusts, and
/// nobody else's certificate will do. So sim-use ships the bridge as
/// *source* and builds it on the user's machine with the user's team —
/// the same trade Appium makes with WebDriverAgent.
///
/// Resolution order, first hit wins:
///   1. An explicit path (`--project-path`, or `SIM_USE_IOS_BRIDGE_PROJECT`).
///   2. The copy bundled into the binary's resources (release installs).
///   3. `ios-bridge/` beside the running binary's source checkout
///      (developer loop — avoids re-syncing resources on every edit).
public enum BridgeRunnerProject {

    public static let projectFileName = "SimUseDeviceBridge.xcodeproj"
    public static let schemeName = "SimUseDeviceBridgeRunner"
    public static let environmentOverride = "SIM_USE_IOS_BRIDGE_PROJECT"

    public enum LocateError: Error, LocalizedError {
        case notFound(searched: [String])
        case notAProject(path: String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let searched):
                return """
                    Could not find the iOS bridge project. Looked in:
                      \(searched.joined(separator: "\n  "))
                    Pass --project-path <dir containing \(projectFileName)>, or set \(environmentOverride).
                    """
            case .notAProject(let path):
                return "\(path) does not contain \(projectFileName)."
            }
        }
    }

    /// Returns the directory containing `SimUseDeviceBridge.xcodeproj`.
    public static func locate(explicit: String? = nil) throws -> URL {
        var searched: [String] = []

        for candidate in candidates(explicit: explicit) {
            searched.append(candidate.path)
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent(projectFileName).path
            ) {
                return candidate
            }
        }

        // An explicit path that exists but has no project is a different
        // mistake from "nothing found anywhere", and deserves its own
        // message.
        if let explicit, FileManager.default.fileExists(atPath: explicit) {
            throw LocateError.notAProject(path: explicit)
        }
        throw LocateError.notFound(searched: searched)
    }

    private static func candidates(explicit: String?) -> [URL] {
        var result: [URL] = []
        if let explicit {
            result.append(URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath))
        }
        if let override = ProcessInfo.processInfo.environment[environmentOverride], !override.isEmpty {
            result.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        if let bundled = Bundle.module.url(forResource: "ios-bridge", withExtension: nil, subdirectory: "Resources") {
            result.append(bundled)
        }
        result.append(contentsOf: developmentCheckoutCandidates())
        return result
    }

    /// Walks up from the executable looking for a repository checkout.
    /// Only useful in the dev loop (`.build/debug/sim-use`), where the
    /// binary sits a few levels under the repo root and the bundled
    /// resource copy may be stale or absent.
    private static func developmentCheckoutCandidates() -> [URL] {
        var directory = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        var result: [URL] = []
        for _ in 0..<6 {
            result.append(directory.appendingPathComponent("ios-bridge", isDirectory: true))
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return result
    }
}
