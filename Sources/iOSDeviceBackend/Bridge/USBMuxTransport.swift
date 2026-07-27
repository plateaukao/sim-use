// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Reaches the on-device bridge over the USB cable by asking `usbmuxd`
/// to open a TCP connection to a port on the phone.
///
/// `usbmuxd` is the daemon Apple ships with Xcode (and with iTunes
/// before that) that multiplexes TCP over the Lightning/USB-C link. It
/// listens on a Unix socket at `/var/run/usbmuxd` and speaks a small
/// plist protocol: `ListDevices` to enumerate what is attached,
/// `Connect` to dial a port. After a successful `Connect` the *same*
/// socket becomes the raw byte stream to that port — which is why this
/// transport can do a whole HTTP exchange without ever binding a local
/// listener.
///
/// That last property is why we do not shell out to `iproxy`: a
/// one-shot CLI has nowhere to keep a forwarding process alive between
/// invocations, and the Android backend's equivalent (`adb forward`)
/// only works because the adb *server* outlives the command. Dialing
/// per request costs about a millisecond and has no lifecycle at all.
public struct USBMuxTransport: BridgeTransport {
    public let udid: String
    public let port: UInt16
    public let socketPath: String

    public init(udid: String, port: UInt16, socketPath: String = USBMuxTransport.defaultSocketPath) {
        self.udid = udid
        self.port = port
        self.socketPath = socketPath
    }

    public static let defaultSocketPath = "/var/run/usbmuxd"

    public var describedEndpoint: String { "usbmux://\(udid):\(port)" }

    public func send(_ request: BridgeHTTPRequest) throws -> BridgeHTTPResponse {
        let deviceID = try Self.deviceID(for: udid, socketPath: socketPath)
        let fd = try Self.connect(deviceID: deviceID, port: port, socketPath: socketPath)
        return try SocketIO.exchange(fd: fd, request: request, host: "127.0.0.1:\(port)")
    }

    // MARK: - Device enumeration

    /// USB-attached devices, keyed by UDID. Also the cheapest "is the
    /// phone plugged in?" probe available, which the client uses to
    /// choose between this transport and the network one.
    public static func attachedUDIDs(socketPath: String = defaultSocketPath) -> [String] {
        guard let devices = try? listDevices(socketPath: socketPath) else { return [] }
        return devices.map(\.udid)
    }

    public struct MuxDevice: Sendable, Equatable {
        public let deviceID: Int
        public let udid: String
        public let connectionType: String
    }

    public static func listDevices(socketPath: String = defaultSocketPath) throws -> [MuxDevice] {
        let fd = try openSocket(socketPath)
        defer { close(fd) }
        let reply = try exchangePlist([
            "MessageType": "ListDevices",
            "ClientVersionString": clientVersion,
            "ProgName": progName,
        ], fd: fd)

        guard let list = reply["DeviceList"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard
                let deviceID = entry["DeviceID"] as? Int,
                let properties = entry["Properties"] as? [String: Any],
                let serial = properties["SerialNumber"] as? String
            else { return nil }
            return MuxDevice(
                deviceID: deviceID,
                // usbmuxd reports the dash-less 24-character form on some
                // macOS versions and the dashed 25-character one on
                // others. Normalise so callers can compare against what
                // `devicectl` prints.
                udid: normalizeUDID(serial),
                connectionType: properties["ConnectionType"] as? String ?? "Unknown"
            )
        }
    }

    /// `00008150000E242411D9401C` → `00008150-000E242411D9401C`.
    /// Leaves the legacy 40-character form and already-dashed IDs alone.
    public static func normalizeUDID(_ serial: String) -> String {
        guard serial.count == 24, !serial.contains("-") else { return serial }
        let index = serial.index(serial.startIndex, offsetBy: 8)
        return "\(serial[..<index])-\(serial[index...])"
    }

    static func deviceID(for udid: String, socketPath: String) throws -> Int {
        let devices = try listDevices(socketPath: socketPath)
        let wanted = normalizeUDID(udid)
        guard let match = devices.first(where: { $0.udid == wanted }) else {
            throw TransportError.notAttached(udid: udid, attached: devices.map(\.udid))
        }
        return match.deviceID
    }

    // MARK: - Connect

    static func connect(deviceID: Int, port: UInt16, socketPath: String) throws -> Int32 {
        let fd = try openSocket(socketPath)
        // usbmuxd wants the port as a big-endian 16-bit value widened to
        // an integer — a raw 8412 dials port 0xDC20 instead of 0x20DC and
        // the connection is refused for no visible reason.
        let reply = try exchangePlist([
            "MessageType": "Connect",
            "DeviceID": deviceID,
            "PortNumber": Int(port.bigEndian),
            "ClientVersionString": clientVersion,
            "ProgName": progName,
        ], fd: fd)

        let number = (reply["Number"] as? Int) ?? -1
        guard number == 0 else {
            close(fd)
            throw TransportError.connectRefused(port: port, code: number, detail: Self.resultDescription(number))
        }
        // The socket is now a raw pipe to the device port.
        return fd
    }

    private static func resultDescription(_ code: Int) -> String {
        switch code {
        case 2: return "device not connected"
        case 3: return "port not available — is the bridge runner still running?"
        case 5: return "malformed request"
        default: return "usbmuxd result \(code)"
        }
    }

    // MARK: - Wire protocol

    /// usbmuxd packet header: 4×UInt32 little-endian —
    /// total length (header included), protocol version (1 = plist),
    /// message type (8 = plist), and a tag echoed back in the reply.
    private static let headerSize = 16
    private static let plistVersion: UInt32 = 1
    private static let plistMessage: UInt32 = 8
    private static let clientVersion = "sim-use"
    private static let progName = "sim-use"

    /// Bounds a hostile or wedged usbmuxd. Real replies are a few KB.
    private static let maxReplyBytes = 4 * 1024 * 1024

    static func openSocket(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.socketUnavailable(path: path, errno: errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw TransportError.socketUnavailable(path: path, errno: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let saved = errno
            close(fd)
            throw TransportError.socketUnavailable(path: path, errno: saved)
        }
        SocketIO.setReceiveTimeout(fd, seconds: 5)
        return fd
    }

    static func exchangePlist(_ payload: [String: Any], fd: Int32) throws -> [String: Any] {
        let body = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        var packet = Data()
        // Header: length (header included), protocol version, message
        // type, tag — four little-endian UInt32s.
        let header: [UInt32] = [UInt32(headerSize + body.count), plistVersion, plistMessage, 1]
        for field in header {
            withUnsafeBytes(of: field.littleEndian) { packet.append(contentsOf: $0) }
        }
        packet.append(body)

        let deadline = Date().addingTimeInterval(5)
        try SocketIO.writeAll(fd, packet, deadline: deadline)

        let response = try SocketIO.readUntil(fd, deadline: deadline) { data in
            guard data.count >= headerSize else { return false }
            let total = Int(data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            guard total <= maxReplyBytes else { throw TransportError.malformedReply("declared length \(total) is implausible") }
            return data.count >= total
        }
        guard response.count > headerSize else {
            throw TransportError.malformedReply("usbmuxd closed before sending a full packet")
        }

        let plistData = response.dropFirst(headerSize)
        guard
            let object = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        else {
            throw TransportError.malformedReply("usbmuxd reply was not a plist dictionary")
        }
        return object
    }
}

public enum TransportError: Error, LocalizedError {
    case socketUnavailable(path: String, errno: Int32)
    case notAttached(udid: String, attached: [String])
    case connectRefused(port: UInt16, code: Int, detail: String)
    case malformedReply(String)
    case noRoute(udid: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .socketUnavailable(let path, let code):
            return "Cannot reach usbmuxd at \(path): \(String(cString: strerror(code))). It ships with Xcode — check that Xcode is installed and the device is trusted."
        case .notAttached(let udid, let attached):
            let list = attached.isEmpty ? "none" : attached.joined(separator: ", ")
            return "Device \(udid) is not attached over USB (usbmuxd sees: \(list)). Plug it in, or connect over Wi-Fi and re-run `sim-use ios-device init`."
        case .connectRefused(let port, _, let detail):
            return "usbmuxd refused a connection to device port \(port): \(detail)."
        case .malformedReply(let detail):
            return "Unexpected usbmuxd reply: \(detail)"
        case .noRoute(let udid, let detail):
            return "No usable route to \(udid): \(detail)"
        }
    }
}
