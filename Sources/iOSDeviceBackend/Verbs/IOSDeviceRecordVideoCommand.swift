// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation
import SimUseCore
import iOSSimBackend

/// `sim-use ios-device record-video` — record a physical device's
/// screen to MP4 through CoreMediaIO (the QuickTime capture route).
/// Host-side only: works without an `ios-device init` bridge session,
/// but needs the phone on USB and camera permission for the terminal.
public struct IOSDeviceRecordVideoCommand: SimUseExecutableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "record-video",
        abstract: "Record the device screen to an MP4 file using H.264 encoding.",
        discussion: """
        Captures over USB via CoreMediaIO — the same mechanism QuickTime's
        "Movie Recording" from an iPhone uses — so the bridge session is not
        required. Wi-Fi-connected devices cannot be recorded; plug the cable in.

        The first run triggers a one-time macOS camera permission prompt for
        your terminal (macOS treats iOS screen capture as camera access).

        Frames arrive at the device's native variable frame rate; --fps is
        ignored, like on Android. Rotating the device stops the recording —
        an MP4 track cannot change frame size — and keeps the partial file.
        """
    )

    @OptionGroup public var device: IOSDeviceOptions

    @Option(help: "Frames per second — ignored on real devices (native variable frame rate); accepted for cross-platform compatibility.")
    public var fps: Int?

    @Option(help: "Quality factor (1-100) controlling bitrate (default: 80)")
    public var quality: Int = 80

    @Option(help: "Scale factor (0.1-1.0, default: 1.0)")
    public var scale: Double = 1.0

    @Option(help: "Output MP4 file path. Defaults to sim-use-video-<timestamp>.mp4 in the current directory.")
    public var output: String?

    @Flag(name: .customLong("json"), help: "Emit the unified `{ok, data: {path}}` envelope.")
    public var jsonOutput: Bool = false

    public init() {}

    public struct ExecutionResult: Codable {
        public let path: String
    }

    public var simulatorUDIDForDaemon: String? { device.resolved }

    /// Recording is interactive (Ctrl+C to stop) and triggers the
    /// camera TCC prompt — both belong to the foreground CLI process,
    /// not the daemon.
    public var daemonBypass: Bool { true }

    public func validate() throws {
        try IOSSimRecordVideoCommand.validateOptions(fps: fps, quality: quality, scale: scale)
    }

    public mutating func resolveDeferredArguments() throws {
        try device.resolve()
    }

    public func execute() async throws -> ExecutionResult {
        let path = try await Self.performRecordVideo(
            udid: device.resolved,
            fps: fps,
            quality: quality,
            scale: scale,
            output: output
        )
        return ExecutionResult(path: path)
    }

    public func format(_ result: ExecutionResult) -> CommandOutput {
        CommandOutput(
            stdout: result.path + "\n",
            stderr: "Recording saved to \(result.path)\n"
        )
    }

    /// Reusable device recording entry point; the top-level
    /// cross-platform `record-video` forwards here. Runs until Ctrl+C
    /// (SIGINT/SIGTERM), mirroring the other platforms' stop contract,
    /// with the same finish watchdog so a wedged writer cannot hang the
    /// process forever after the user asked it to stop.
    public static func performRecordVideo(
        udid: String,
        fps: Int?,
        quality: Int,
        scale: Double,
        output: String?
    ) async throws -> String {
        let outputURL = try IOSSimRecordVideoCommand.prepareOutputURL(output: output)
        FileHandle.standardError.write(Data("Recording iOS device \(udid) to \(outputURL.path)\n".utf8))
        FileHandle.standardError.write(Data("Press Ctrl+C to stop recording\n".utf8))

        let cancellationFlag = CancellationFlag()
        let recordingFinished = CancellationFlag()
        let signalObserver = SignalObserver(signals: [SIGINT, SIGTERM]) {
            cancellationFlag.cancel()
            RecordingFinishWatchdog.arm(recordingFinished: recordingFinished)
        }
        defer { signalObserver.invalidate() }

        do {
            try await IOSDeviceScreenRecorder.record(
                udid: udid,
                fps: fps,
                quality: quality,
                scale: scale,
                outputURL: outputURL,
                cancellationFlag: cancellationFlag
            )
            recordingFinished.cancel()
            return outputURL.path
        } catch {
            recordingFinished.cancel()
            throw error
        }
    }
}
