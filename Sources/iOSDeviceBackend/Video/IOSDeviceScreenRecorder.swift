// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreMediaIO
import Foundation
import os
import SimUseCore
import iOSSimBackend

/// Records a physical iOS device's screen through CoreMediaIO — the
/// mechanism behind QuickTime's "Movie Recording from iPhone". The
/// phone appears to the host as an external capture device once the
/// process opts in; an `AVCaptureSession` then delivers its screen as
/// BGRA frames that feed the shared `H264StreamRecorder`.
///
/// Wholly host-side: this path never touches the XCUITest bridge, so
/// `record-video` works without an `ios-device init` session. Two hard
/// requirements instead:
///
///   * **USB.** The screen-capture device does not materialise for
///     Wi-Fi-connected phones.
///   * **Camera permission.** macOS gates iOS screen capture behind the
///     camera TCC prompt, attributed to the terminal running sim-use.
///
/// Frame timing mirrors the Android path: native variable frame rate,
/// PTS from the capture clock (zero-based), `--fps` ignored with a
/// note. A mid-recording rotation stops the capture — an MP4 track
/// cannot change frame size — preserving the partial file, exactly as
/// on Android.
public enum IOSDeviceScreenRecorder {

    /// How long to wait for the phone to enumerate as a capture device
    /// after the CMIO opt-in. Cold appearance takes 1–3 s; the margin
    /// covers a device that was plugged in just before the command.
    static let deviceDiscoveryTimeout: TimeInterval = 10

    /// How long to wait for the first frame once the session runs.
    static let firstFrameTimeout: TimeInterval = 10

    // MARK: - CoreMediaIO plumbing

    /// Opt this process into seeing iOS screen-capture devices. System
    /// default is off; QuickTime flips the same switch.
    static func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
    }

    /// One 50 ms slice of the main run loop. Synchronous on purpose:
    /// Swift marks `CFRunLoopRunInMode` unavailable from async contexts
    /// because blocking a cooperative thread is usually a bug — here it
    /// is the point. `record()` is main-actor-bound and the DAL
    /// plugin's device/property callbacks arrive on this run loop, so
    /// the waits must service it, exactly as an AVFoundation app would.
    @MainActor
    private static func pumpMainRunLoop() {
        CFRunLoopRunInMode(.defaultMode, 0.05, true)
    }

    /// On older macOS the capture device's `uniqueID` was the phone's
    /// UDID; normalise hyphens/case for that comparison.
    static func normalizedID(_ raw: String) -> String {
        raw.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Discovery MUST pump the main run loop: the iOSScreenCapture DAL
    /// plugin delivers device arrivals through run-loop callbacks, so a
    /// thread that merely sleeps sees an empty device list forever —
    /// that failure mode looks exactly like "macOS refuses this phone"
    /// and cost a wrong diagnosis once. Runs on the main actor so the
    /// pumped loop is the one the plugin registered with.
    ///
    /// Matching, in order: `uniqueID` == UDID (older macOS published it
    /// that way); the device's name as reported by devicectl (current
    /// macOS mints a fresh UUID for `uniqueID`, and the name is the only
    /// surfaced link back to the phone); after a settling period, a
    /// *sole* connected iOS device is accepted with a note.
    @MainActor
    static func findCaptureDevice(udid: String, deviceName: String?, timeout: TimeInterval) throws -> AVCaptureDevice {
        let wantedID = normalizedID(udid)
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        let singletonFallbackAfter = start.addingTimeInterval(2)
        repeat {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
            let discovered = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external],
                mediaType: nil,
                position: .unspecified
            ).devices
            if let match = discovered.first(where: { normalizedID($0.uniqueID) == wantedID }) {
                return match
            }
            if let deviceName, let match = discovered.first(where: { $0.localizedName == deviceName }) {
                return match
            }
            let iosDevices = discovered.filter { $0.modelID == "iOS Device" }
            if iosDevices.count == 1, Date() >= singletonFallbackAfter, let only = iosDevices.first {
                FileHandle.standardError.write(Data(
                    "note: matching by sole connected iOS capture device (\(only.localizedName))\n".utf8
                ))
                return only
            }
        } while Date() < deadline
        throw CLIError(errorDescription: """
            \(udid) is not visible to macOS as a screen-capture device. Screen recording \
            needs the phone on **USB** (a Wi-Fi connection is not enough) — plug the cable \
            in, tap Trust if prompted, and retry. If another app is already capturing it \
            (QuickTime, OBS, …), stop that recording first.
            """)
    }

    static func ensureCameraAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw cameraDeniedError
            }
        default:
            throw cameraDeniedError
        }
    }

    private static var cameraDeniedError: CLIError {
        CLIError(errorDescription: """
            macOS treats iOS screen capture as camera access, and it is not granted. Enable \
            it for your terminal under System Settings → Privacy & Security → Camera, then \
            retry.
            """)
    }

    // MARK: - Recording

    @MainActor
    public static func record(
        udid: String,
        fps: Int?,
        quality: Int,
        scale: Double,
        outputURL: URL,
        cancellationFlag: CancellationFlag
    ) async throws {
        if fps != nil {
            FileHandle.standardError.write(Data("note: --fps is ignored on real iOS devices (capture arrives at the device's native variable frame rate)\n".utf8))
        }

        allowScreenCaptureDevices()
        try await ensureCameraAccess()
        // The capture device's uniqueID no longer carries the UDID, so
        // the phone's name is the identifying link — fetch it up front.
        let deviceName = (try? DeviceCtl().devices())?.first { $0.udid == udid }?.name
        let device = try findCaptureDevice(udid: udid, deviceName: deviceName, timeout: deviceDiscoveryTimeout)

        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CLIError(errorDescription: """
                Could not open \(device.localizedName) for capture: \(error.localizedDescription). \
                If QuickTime or another app is recording this device, stop it first.
                """)
        }
        guard session.canAddInput(input) else {
            throw CLIError(errorDescription: "Could not attach \(device.localizedName) to a capture session.")
        }
        session.addInput(input)

        let sink = ScreenRecordingSink(outputURL: outputURL, fps: fps ?? 30, quality: quality, scale: scale)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        // Screen capture must not drop frames silently — but a stalled
        // writer is surfaced by the sink, so late frames may drop rather
        // than queue without bound.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(sink, queue: DispatchQueue(label: "sim-use.ios-device.record"))
        guard session.canAddOutput(output) else {
            throw CLIError(errorDescription: "Could not attach a video output to the capture session.")
        }
        session.addOutput(output)

        // Cable pulled or the DAL device died mid-recording: stop and
        // keep the partial file, mirroring the Android disconnect path.
        let disconnected = CancellationFlag()
        let observers = [
            NotificationCenter.default.addObserver(
                forName: .AVCaptureDeviceWasDisconnected,
                object: nil,
                queue: nil
            ) { [wanted = normalizedID(udid)] notification in
                guard
                    let gone = notification.object as? AVCaptureDevice,
                    normalizedID(gone.uniqueID) == wanted
                else { return }
                disconnected.cancel()
            },
            NotificationCenter.default.addObserver(
                forName: .AVCaptureSessionRuntimeError,
                object: session,
                queue: nil
            ) { notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                sink.fatal.set(CLIError(errorDescription: "Capture session failed: \(error?.localizedDescription ?? "unknown error")"))
                disconnected.cancel()
            },
        ]
        defer { observers.forEach(NotificationCenter.default.removeObserver(_:)) }

        session.startRunning()
        defer { if session.isRunning { session.stopRunning() } }

        // Both waits alternate a run-loop slice with a task yield. The
        // pump services the DAL plugin's device/property events (which
        // are run-loop-delivered, same as during discovery); the yield
        // releases the main *dispatch* queue so `SignalObserver`'s
        // handler — a main-queue DispatchSource — can set the
        // cancellation flag. Pumping alone starves that handler and
        // Ctrl+C never lands; that exact hang happened on first live
        // test.
        // First frame proves the pipeline is live (and sizes the writer).
        let firstFrameDeadline = Date().addingTimeInterval(firstFrameTimeout)
        while !sink.firstFrameSeen.isCancelled() {
            if cancellationFlag.isCancelled() || disconnected.isCancelled() || sink.fatal.first != nil { break }
            guard Date() < firstFrameDeadline else {
                throw CLIError(errorDescription: """
                    The capture session is running but no frames arrived within \
                    \(Int(firstFrameTimeout))s. Unplug and replug the device, or reboot it, \
                    then retry.
                    """)
            }
            pumpMainRunLoop()
            await Task.yield()
        }

        while !cancellationFlag.isCancelled() && !sink.stopped.isCancelled() && !disconnected.isCancelled() {
            pumpMainRunLoop()
            await Task.yield()
        }

        sink.stopAppending()
        session.stopRunning()

        try await sink.finish()

        if let fatal = sink.fatal.first {
            throw fatal
        }
        if sink.rotated.isCancelled() {
            throw CLIError(errorDescription: """
                The device display changed size mid-recording (rotation) — an MP4 track \
                cannot change frame size. Partial recording saved to \(outputURL.path)
                """)
        }
        if disconnected.isCancelled() {
            throw CLIError(errorDescription: "The device disconnected during recording; partial recording saved to \(outputURL.path)")
        }
        if sink.framesAppended == 0 {
            throw CLIError(errorDescription: "No frames were captured; nothing was recorded.")
        }
    }
}

/// Feeds captured frames into an `H264StreamRecorder` created lazily on
/// the first frame (which is what reveals the native dimensions).
/// Callbacks arrive serially on the capture queue; all mutable state is
/// confined behind one lock so the orchestrator can safely finish the
/// recorder after `stopRunning()`.
final class ScreenRecordingSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let outputURL: URL
    private let fps: Int
    private let quality: Int
    private let scale: Double

    /// Latches, readable from any thread.
    let firstFrameSeen = CancellationFlag()
    let rotated = CancellationFlag()
    let stopped = CancellationFlag()
    let fatal = FirstErrorBox()

    private struct State {
        var recorder: H264StreamRecorder?
        var nativeWidth = 0
        var nativeHeight = 0
        var firstPTS: CMTime?
        var lastPTS = CMTime.zero
        var framesAppended: Int64 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var framesAppended: Int64 { state.withLock { $0.framesAppended } }

    init(outputURL: URL, fps: Int, quality: Int, scale: Double) {
        self.outputURL = outputURL
        self.fps = fps
        self.quality = quality
        self.scale = scale
    }

    func stopAppending() {
        stopped.cancel()
    }

    /// Marks the writer finished and finalizes the MP4. Safe to call
    /// once appends have been stopped; invalidates on failure so a
    /// wedged writer never leaves a zombie file handle.
    func finish() async throws {
        stopped.cancel()
        let recorder = state.withLock { state -> H264StreamRecorder? in
            let r = state.recorder
            state.recorder = nil
            return r
        }
        guard let recorder else { return }
        do {
            try await recorder.finish()
        } catch {
            recorder.invalidate()
            throw error
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !stopped.isCancelled() else { return }
        guard let rawBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // The lock's closure is @Sendable; the buffer never leaves this
        // call (append copies/retains what it needs), so the transfer
        // is safe.
        let boxed = UncheckedSendableBox(value: rawBuffer)
        let width = CVPixelBufferGetWidth(rawBuffer)
        let height = CVPixelBufferGetHeight(rawBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        do {
            try state.withLock { state in
                if state.recorder == nil {
                    state.nativeWidth = width
                    state.nativeHeight = height
                    let dims = Self.scaledEvenDimensions(width: width, height: height, scale: scale)
                    state.recorder = try H264StreamRecorder(
                        outputURL: outputURL,
                        width: dims.width,
                        height: dims.height,
                        fps: fps,
                        quality: quality
                    )
                    firstFrameSeen.cancel()
                }
                guard width == state.nativeWidth, height == state.nativeHeight else {
                    rotated.cancel()
                    stopped.cancel()
                    return
                }
                guard let recorder = state.recorder else { return }

                if state.firstPTS == nil { state.firstPTS = pts }
                var relative = CMTimeSubtract(pts, state.firstPTS!)
                // Guard against clock jitter: PTS must be strictly
                // monotonic or the writer rejects the frame.
                if state.framesAppended > 0, CMTimeCompare(relative, state.lastPTS) <= 0 {
                    relative = CMTimeAdd(state.lastPTS, CMTime(value: 1, timescale: 600))
                }

                if scale >= 1.0 {
                    try recorder.append(pixelBuffer: boxed.value, presentationTime: relative)
                } else {
                    guard let image = Self.makeCGImage(from: boxed.value) else { return }
                    try recorder.append(image: image, presentationTime: relative)
                }
                state.lastPTS = relative
                state.framesAppended += 1
            }
        } catch {
            fatal.set(error)
            stopped.cancel()
        }
    }

    /// Same even-dimension rounding as the other recording paths (most
    /// H.264 encoders reject odd dimensions).
    static func scaledEvenDimensions(width: Int, height: Int, scale: Double) -> (width: Int, height: Int) {
        let scaledWidth = max(2, Int(Double(width) * scale))
        let scaledHeight = max(2, Int(Double(height) * scale))
        return (max(scaledWidth - (scaledWidth % 2), 2), max(scaledHeight - (scaledHeight % 2), 2))
    }

    private struct UncheckedSendableBox<T>: @unchecked Sendable {
        let value: T
    }

    /// BGRA CVPixelBuffer → CGImage for the scaling append path.
    /// `makeImage()` copies, so unlocking after is safe.
    private static func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        return context.makeImage()
    }
}
