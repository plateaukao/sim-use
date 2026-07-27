// SPDX-License-Identifier: Apache-2.0
import ArgumentParser
import Foundation

/// The `sim-use ios-device <sub>` namespace — real iPhones and iPads,
/// as opposed to `sim-use ios` (Simulator) and `sim-use android`.
///
/// Named `ios-device` rather than `device` because "device" is already
/// ambiguous: an Android phone is a device too, and `--device` is the
/// flag every verb takes.
///
/// Two verbs have no counterpart in the other namespaces —
/// `init` / `stop` — because a real device's automation session is a
/// live process on the host rather than an installed app. See
/// `Runner/BridgeRunnerLauncher.swift` for why that is unavoidable.
public struct IOSDeviceCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ios-device",
        abstract: "Real iOS device subcommands (init, describe-ui, tap, …).",
        discussion: """
        Drives a physical iPhone or iPad through an on-device XCUITest bridge.

        Unlike Android — where `sim-use android init` installs a prebuilt APK —
        the iOS bridge must be **built and signed with your own Apple developer
        team**, because iOS only grants cross-app accessibility and event
        injection to a test runner the device trusts. `init` does that build
        for you and then holds the session open:

          sim-use ios-device init --team-id ABCDE12345
          sim-use ios-device describe-ui
          sim-use ios-device tap @3
          sim-use ios-device stop

        The session lives as long as the `xcodebuild` process `init` started.
        It ends if you run `stop`, reboot the phone, or unplug it on a USB-only
        setup — re-run `init` to bring it back.

        Requirements: Xcode 15+, Developer Mode enabled on the device
        (Settings → Privacy & Security), the device unlocked at `init` time,
        and an Apple Development signing identity.
        """,
        subcommands: [
            IOSDeviceInitCommand.self,
            IOSDeviceStopCommand.self,
            IOSDeviceStatusCommand.self,
            IOSDeviceDevicesCommand.self,
            IOSDeviceDescribeUICommand.self,
            IOSDeviceTapCommand.self,
            IOSDeviceSwipeCommand.self,
            IOSDeviceTypeCommand.self,
            IOSDevicePasteCommand.self,
            IOSDeviceScreenshotCommand.self,
            IOSDeviceKeyboardStateCommand.self,
            IOSDeviceButtonCommand.self,
        ]
    )

    public init() {}
}
