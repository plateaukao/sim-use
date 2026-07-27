// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Launch-time configuration handed to the runner by the host.
///
/// Unlike the Android bridge — which mints its own bearer token and
/// surfaces it to `adb shell content query` through a ContentProvider —
/// the iOS runner has no channel back to the host other than its own
/// stdout. So the host generates the token and injects it through the
/// `.xctestrun` `EnvironmentVariables` dict before
/// `xcodebuild test-without-building`, and we read it here. That
/// inverts who mints the secret but removes an entire IPC surface
/// (`SimuseContentProvider` + `AuthTokenFetcher`) from the iOS side.
///
/// Every value has a defensible default so the bundle is still runnable
/// straight from Xcode's Test action while developing handlers.
struct BridgeConfig {
    let port: UInt16
    let token: String

    /// `true` when the host did not supply a token. Development-only
    /// mode: the generated token is printed on the ready line so a
    /// human driving the runner from Xcode can copy it.
    let tokenWasGenerated: Bool

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> BridgeConfig {
        let port = env[EnvKey.port].flatMap(UInt16.init) ?? defaultPort
        if let token = env[EnvKey.token], !token.isEmpty {
            return BridgeConfig(port: port, token: token, tokenWasGenerated: false)
        }
        return BridgeConfig(port: port, token: UUID().uuidString, tokenWasGenerated: true)
    }

    enum EnvKey {
        static let port = "SIMUSE_BRIDGE_PORT"
        static let token = "SIMUSE_BRIDGE_TOKEN"
    }

    /// Deliberately not 8100 (WebDriverAgent's default) so a sim-use
    /// bridge and a WDA session can coexist on one device without the
    /// second one failing to bind.
    static let defaultPort: UInt16 = 8412
}

/// Non-loopback addresses the runner is reachable at, for the Wi-Fi
/// transport. Over USB the host reaches us through usbmux and ignores
/// these entirely.
enum HostAddresses {
    static func local() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [String] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = ptr.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard rc == 0 else { continue }
            var text = String(cString: host)
            // Strip the scope suffix from link-local IPv6
            // (`fe80::1%en0`) — it is meaningless on the host side.
            if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
            if text.hasPrefix("fe80:") { continue }
            if !result.contains(text) { result.append(text) }
        }
        // IPv4 first: the host's happy path, and shorter to log.
        return result.sorted { lhs, rhs in
            let lhsV4 = !lhs.contains(":")
            let rhsV4 = !rhs.contains(":")
            if lhsV4 != rhsV4 { return lhsV4 }
            return lhs < rhs
        }
    }
}
