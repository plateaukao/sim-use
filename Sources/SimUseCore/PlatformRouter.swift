// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The platforms `sim-use` can target: iOS Simulator, Android
/// device/emulator, and real iOS devices (driven by the on-device
/// XCUITest bridge in `ios-bridge/`).
public enum Platform: Equatable {
    case iOSSim
    case android
    case iOSDevice
}

/// Centralises the UDID-shape heuristics used to decide which backend
/// owns a command invocation. Top-level forwarders ask
/// `PlatformRouter.resolve(udid:)` instead of carrying their own
/// `looksLikeAndroid` checks (the pattern that grew to ~17 sites and
/// motivated this module).
///
/// Resolution layers, in priority order:
///   1. Explicit `--platform` flag — handled by the caller; we accept
///      a pre-resolved override.
///   2. Daemon pidfile platform tag — also caller-side (the daemon
///      knows its own platform).
///   3. UDID-shape inference (this module).
public enum PlatformRouter {

    /// Classify a UDID into a target platform. Returns `nil` when the
    /// shape doesn't fit any known platform; callers can choose to fail
    /// fast or fall back to a default.
    public static func resolve(udid: String) -> Platform? {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        // Real-device UDIDs must be classified *before* the Android
        // check: the modern 25-character form (`00008150-000E…`) is all
        // hex and dashes within adb's length bounds, so `looksLikeAndroid`
        // matches it and would send every iPhone down the adb path.
        if looksLikeIOSDevice(trimmed) { return .iOSDevice }
        if looksLikeAndroid(trimmed) { return .android }
        if looksLikeIOSSim(trimmed) { return .iOSSim }
        return nil
    }

    /// `true` when the UDID looks like an iOS Simulator UDID
    /// (8-4-4-4-12 hex, as emitted by `simctl list`).
    public static func looksLikeIOSSim(_ udid: String) -> Bool {
        let pattern = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        return udid.range(of: pattern, options: .regularExpression) != nil
    }

    /// `true` when the UDID looks like a real iOS device identifier.
    ///
    /// Apple has shipped two shapes:
    ///   - **Modern (A12 / iOS 12+)**: `00008150-000E242411D9401C` —
    ///     8 hex, a dash, 16 hex. The leading group is the chip
    ///     identifier, so it always starts `0000`.
    ///   - **Legacy (pre-A12)**: 40 hex characters, no separators.
    ///
    /// Both are unambiguous against the other platforms: a Simulator
    /// UDID is 8-4-4-4-12 (four dashes, not one), and no adb serial is
    /// 40 hex characters or carries the `0000…-…` chip-id prefix.
    /// Length-40 is checked before the dashed form because the legacy
    /// shape has no dash at all.
    public static func looksLikeIOSDevice(_ udid: String) -> Bool {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        let isHex: (Character) -> Bool = { $0.isHexDigit && $0.isASCII }

        if trimmed.count == 40, trimmed.allSatisfy(isHex) {
            return true
        }

        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        guard parts[0].count == 8, parts[1].count == 16 else { return false }
        guard parts[0].allSatisfy(isHex), parts[1].allSatisfy(isHex) else { return false }
        return true
    }

    /// `true` when the UDID looks like an Android serial.
    ///
    /// Heuristic, in order:
    ///   1. `emulator-…` prefix → always Android.
    ///   2. iOS Simulator or real-iOS-device UDID shape → never Android.
    ///   3. ASCII-only, length 4–32, allowed `[A-Za-z0-9._:-]`, with at
    ///      least one digit → Android.
    ///
    /// Rule 3 keeps typos like `--udid foo` (too short) or
    /// `--udid mycoolphone` (no digits) out of the adb path; they fall
    /// through to the iOS resolver, which surfaces a clearer error
    /// faster than waiting 5 s for `adb -s <typo> …` to time out.
    public static func looksLikeAndroid(_ udid: String) -> Bool {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.hasPrefix("emulator-") { return true }
        if looksLikeIOSSim(trimmed) { return false }
        if looksLikeIOSDevice(trimmed) { return false }
        guard trimmed.count >= 4, trimmed.count <= 32 else { return false }
        let allowed: (Character) -> Bool = { ch in
            ch.isASCII && (
                ch.isLetter || ch.isNumber || ch == "-" || ch == "." || ch == ":" || ch == "_"
            )
        }
        guard trimmed.allSatisfy(allowed) else { return false }
        guard trimmed.contains(where: { $0.isNumber }) else { return false }
        return true
    }
}