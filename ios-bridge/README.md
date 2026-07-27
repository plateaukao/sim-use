# sim-use iOS device bridge

XCUITest runner that serves the sim-use bridge HTTP API from inside a real
iPhone or iPad, driven from the host by the sim-use CLI over usbmux (USB) or
TCP (Wi-Fi).

This is the iOS counterpart of `bridge/` (the Kotlin Android app), but the
shape is forced to be different — see below.

## Why this is a test bundle and not an app

Android exposes `AccessibilityService`: any installed app can, with the user's
consent, read another app's view tree and inject gestures. That is what makes
`sim-use-device-bridge.apk` possible.

iOS has no equivalent. The only process on a non-jailbroken device that can see
another app's accessibility tree or synthesize touches is one that `testmanagerd`
is supervising — an XCUITest runner. Those privileges begin when the test method
starts and end when it returns. So the bridge is a UI-test bundle whose single
test starts an HTTP server and never returns, and the host keeps an `xcodebuild
test-without-building` process alive for the length of the session.

WebDriverAgent has the same design for the same reason.

Three consequences fall out of this, and they are the whole reason the iOS and
Android backends differ:

| | Android | iOS device |
|---|---|---|
| Distribution | prebuilt APK, installable anywhere | **source**; built and signed with the user's own team |
| Lifetime | installed until uninstalled | lives as long as the host's `xcodebuild` process |
| Bootstrap | `adb install` + settings writes | `xcodebuild build-for-testing` + `test-without-building` |
| Auth token | app mints it, host reads it via ContentProvider | host mints it, injects it via the `.xctestrun` environment |
| Transport | `adb forward` | usbmux (USB) or direct TCP (Wi-Fi) |

## Wire protocol

Same envelope as the Android bridge (`{"status": "success", "result": …}`,
`result` is inline JSON, never a JSON-encoded string) and the same endpoint
names, so one mental model covers both.

| Endpoint | Method | Notes |
|---|---|---|
| `/ping` | GET | Unauthenticated. Flat envelope with `protocol_version`, `bridge_version`, `platform`. |
| `/diag` | GET | Which XCUIAutomation SPI resolved on this Xcode. |
| `/a11y_tree_full` | GET | `filter`, `bundle_id`. **`result` is an array of iOS AX elements.** |
| `/screenshot` | GET | `scale` (0–1) downsamples on-device. Base64 PNG. |
| `/tap` | POST | `x`, `y`, `duration` (ms; makes it a long-press). |
| `/swipe` | POST | `startX`, `startY`, `endX`, `endY`, `duration`. |
| `/gesture` | POST | `strokes` — same JSON stroke format as the Android bridge. |
| `/keyboard/input` | POST | `base64_text`, `clear`. |
| `/keyboard/key` | POST | `key` — a **name** (`return`, `delete`, …), not Android's numeric keycode. |
| `/keyboard/state` | GET | `visible`, `owner`, `frame`, `detection`. See below. |
| `/button` | POST | `name`: `home`, `lock`, `volumeup`, `volumedown`. |
| `/paste` | POST | `base64_text`, `replace`, `clipboard_only`. |

### The one deliberate divergence

`/a11y_tree_full` returns an **iOS** accessibility tree — an array of elements
with `type` / `frame` / `children` / `enabled` / `AXLabel` / `AXUniqueId` /
`AXValue` — which is exactly the shape idb returns for the iOS Simulator, not
the Android `ElementNode` shape.

That is the point. Because the shapes match, the host reuses
`OutlineFormatter`, `ListDetector`, and every selector from `iOSSimBackend`
unchanged, and `describe-ui` output plus `@N` aliases are identical between a
simulator and a phone. `protocol_version` is therefore an independent lineage
from the Android bridge's; the two numbers are not comparable.

### Keyboard detection is a ladder, not a lookup

`/keyboard/state` reports which of four strategies answered, in
`detection`. It has to, because **a third-party keyboard runs in its own
extension process and its elements never appear in the foreground app's
snapshot.** Measured on an iPhone 17 Pro with 蝦米輸入法 active: the keyboard
was plainly on screen, Spotlight was foreground and focused, and neither
Spotlight's nor SpringBoard's tree contained a single `Keyboard` or `Key`
element.

| `detection` | Signal | Frame? |
|---|---|---|
| `query` | `XCUIApplication.keyboards` (XCTest's query engine) | yes |
| `snapshot` | a `Keyboard` element with real bounds | yes |
| `keys` | ≥5 `Key` elements whose container didn't survive | yes (union) |
| `focus` | a focused text input — orthogonal to the above, and the only one that catches an out-of-process IME | **no** |
| `none` | nothing found | — |

`focus` proves the keyboard is up but not where it is, so callers that
need the occluded region must handle a missing frame rather than assume
one.

## Building

Normally you do not build this directly — `sim-use ios-device init` does it.
To work on the bridge itself:

```bash
# Compile-check against the Simulator SDK (no signing, no device needed)
scripts/build-ios-bridge.sh --compile

# Build and run on a real device
cd ios-bridge
xcodebuild build-for-testing \
  -project SimUseDeviceBridge.xcodeproj \
  -scheme SimUseDeviceBridgeRunner \
  -destination 'id=<UDID>' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<TEAMID>
```

`SimUseDeviceBridge.xcodeproj` is committed so contributors need only Xcode.
It is generated from `project.yml`; after adding, removing, or moving a source
file, regenerate it:

```bash
brew install xcodegen
scripts/build-ios-bridge.sh --generate
```

## Layout

```
ios-bridge/
├── project.yml                        # XcodeGen spec (regeneration recipe)
├── SimUseDeviceBridge.xcodeproj/      # committed, generated from project.yml
├── Support/Info.plist
└── Sources/SimUseDeviceBridgeRunner/
    ├── BridgeTestCase.swift           # the never-returning XCTestCase
    ├── config/
    │   ├── BridgeConfig.swift         # token + port from the launch environment
    │   └── BridgeVersion.swift        # protocol / bridge version constants
    ├── handler/                       # one file per verb family
    │   ├── CaptureHandler.swift       # /screenshot
    │   ├── GestureHandler.swift       # /tap, /swipe, /gesture
    │   ├── InputHandler.swift         # /keyboard/input, /keyboard/key, /button
    │   ├── KeyboardStateHandler.swift # /keyboard/state
    │   ├── PasteHandler.swift         # /paste
    │   └── SnapshotHandler.swift      # /a11y_tree_full
    ├── model/AXNode.swift             # iOS AX wire shape + element-type table
    ├── server/
    │   ├── ActionRouter.swift         # (method, path) dispatch + bearer auth
    │   ├── Envelope.swift
    │   ├── HTTPMessage.swift          # request parse / response serialise
    │   ├── HTTPServer.swift           # BSD-socket accept loop
    │   └── SerialWorkQueue.swift      # funnels handlers onto the test thread
    └── xcui/SimUsePrivateAPI.{h,m}    # guarded XCUIAutomation SPI shims
```

### Compose Multiplatform apps

Verified against a Compose Multiplatform iOS app (EinkBro). It works — Compose
maps its semantics tree to real iOS accessibility elements, so buttons arrive
with usable labels and identifiers (`Button "Input URL" #inputurl`) and frames
are accurate enough to tap. Two differences from a UIKit app are worth knowing:

- **Text-field contents arrive in `AXLabel`, not `AXValue`.** A native
  `UITextField` puts its text in `AXValue` and its placeholder in `AXLabel`;
  Compose puts the text in `AXLabel` and leaves `AXValue` nil. Anything reading
  a field's current contents must check both — `InputHandler.focusedValueLength`
  does, and the `type --clear` bug that motivated it (zero backspaces sent, new
  text appended to old) is exactly what happens when you only read `AXValue`.
- **The Skia canvas shows up as generic full-screen `Other` elements.** Harmless
  noise in the outline; `?filter=true` trims the zero-size ones.

Elements with no Compose semantics are invisible to accessibility and therefore
to the bridge — the same discipline Compose already requires on Android.

## The SPI shims

`xcui/SimUsePrivateAPI.m` forward-declares the `XCUIAutomation` interfaces
XCTest exposes to a test process but does not publish: `XCPointerEventPath`,
`XCSynthesizedEventRecord`, `XCUISystem.activeForegroundApplications`,
`XCUIDevice.pressLockButton`. Nothing links against a private symbol — the
classes are resolved at runtime — so a future Xcode that renames one degrades
to a structured error instead of a launch-time crash.

Two hard-won details worth keeping:

- **Event submission has moved between Xcode releases.** On iOS the working
  route is `-[XCSynthesizedEventRecord synthesizeWithError:]`. The
  macOS-flavoured `-[XCUIDevice performDeviceEvent:error:]` *exists* on iOS but
  calls `-duration` on the record, which the iOS class does not implement — it
  raises rather than returning an error. `SimUseSubmitEvent` tries the three
  known routes in order.
- **Every handler runs inside an exception trap.** Swift cannot catch
  `NSException`, and an uncaught one unwinds through the test method and ends
  the session — one bad request turns into "the phone stopped responding".
  `SimUseExceptionTrap` converts it into a 500.

If the bridge misbehaves after an Xcode upgrade, `GET /diag` reports what
resolved, on-device, without a rebuild.

## Test

The runner has no unit tests of its own; its host-side contract (HTTP framing,
the ready handshake, the `.xctestrun` patch) is covered by
`Tests/iOSDeviceBackendTests/`, which needs no device.
