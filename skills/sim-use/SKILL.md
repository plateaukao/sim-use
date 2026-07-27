---
name: sim-use
description: Drive iOS Simulator, real iPhone/iPad, and Android emulator/device screens for AI agents. Use when asked to automate a simulator, emulator, or connected phone, tap/swipe/type on a device, describe UI, take a screenshot, or interact with a mobile app.
---

## 0. Preflight

Before first interaction with a device, run the preflight check:

```bash
python3 scripts/preflight.py --device <UDID>
```

This verifies sim-use is installed, the device is reachable, and the daemon is healthy. If you don't have the script, do the checks manually:

1. `sim-use --version` — confirm sim-use is on PATH.
2. `sim-use devices` — confirm the target device is listed and booted/connected.
3. `sim-use ui --device <UDID>` — confirm you can read the screen.

`--device` is optional when only one simulator is booted or one daemon is running.

Per-platform bootstrap:

- **Android** — `sim-use android init --device <serial>` once, to install the bridge APK.
- **Real iPhone / iPad** — `sim-use ios-device init` **each session**. Unlike Android, the
  iOS bridge is a live XCUITest session, not an installed app: it ends when the host
  process stops, the phone reboots, or (on USB-only setups) the cable is pulled.
  `sim-use ios-device status` tells you whether it is still up; re-run `init` if not.
  The phone must be **unlocked** when `init` runs, and needs Developer Mode enabled.
  If `init` reports no signing team, ask the user for their Apple Development team ID
  rather than guessing — you cannot discover it reliably.

## 1. The observe-act loop

Every interaction follows the same cycle: **observe → act → verify**.

### Observe

```bash
sim-use ui --device <UDID>
```

Read the outline. Each element has an `@N` alias and optionally a `#<id>` identifier. List cells carry `#N` (dominant list) or `#N@M` (scoped).

Frames in the JSON output (`--json`: `entries[].frame`, `screen`) are in platform-native units — iOS **points** (both Simulator and real device), Android **pixels**. Key off the envelope's `platform` field (`ios`, `ios-device`, `android`) before doing math on coordinates across platforms. Always pair `--json` with `--no-raw` — see *Keeping output small* below.

### Act

Pick a selector, in order of preference:

| Selector | When to use |
|---|---|
| `tap @N` | Right after `ui`. Fastest, cache-backed. |
| `tap #<id>` | Stable across minor layout changes. Paste from the outline. |
| `tap --label 'X'` | Scripted flows. Combine with `--wait-timeout` for transitions. |
| `tap --label-regex '...'` | Dynamic labels with counters/timestamps. Anchor with `^...$`. |
| `tap --label-contains 'X'` | Substring match when exact label is unknown. |
| `tap -x N -y N` / `tap --point x,y` | Last resort for elements with no AX data. |

Disambiguate collisions with `--element-type` or `--frame minY=0.7r` (see `references/cheatsheet.md`).

### Verify

Always verify after acting — commands are fire-and-forget:

```bash
sim-use ui --device <UDID>       # read the new screen state
sim-use screenshot --device <UDID> --output after.png
```

### Keeping output small

Every byte of command output you read costs context. Defaults that keep the loop cheap:

- Prefer the default text outline over `--json`. The outline carries everything a tap needs (`@N` / `#<id>` aliases, roles, frames, states); reach for `--json` when you need structured fields for coordinate math (`entries[].frame`, `screen`) or full untruncated text (the outline truncates labels at 60 graphemes, `value=` at 30).
- When you do use `--json`, add `--no-raw`. `data.raw` is the raw accessibility tree — typically the bulk of the envelope's bytes, and useful only for debugging sim-use itself.
- One `ui` per action: the Verify read of step N is the Observe read of step N+1. Don't run a second `ui` in between.
- Verify with the text outline, not a screenshot. Reading a screenshot costs several times more than a typical outline; take one only when the check is genuinely visual (colors, images, layout).
- On iOS, to wait out a transition, prefer `tap --label 'X' --wait-timeout 3` (polls for the element) over re-running `ui` in a loop. Android `tap` has no `--wait-timeout`; use `sleep` between commands instead.
- For a known multi-step sequence on iOS, use `sim-use ios batch` (see `references/batch-reference.md`) — one invocation, one output.

### Common moves

| Task | Command |
|---|---|
| Scroll down | `sim-use gesture scroll-up --device <UDID>` (scroll-up = content moves up = page down) |
| Type text | `sim-use type 'hello' --device <UDID>` |
| Paste unicode | `sim-use paste 'こんにちは 🎉' --device <UDID>` (iOS: needs hardware keyboard) |
| Hardware button | `sim-use button home --device <UDID>` |
| Android back | `sim-use button back --device <UDID>` |
| Wait for animation | `sleep 0.4` between commands, or `--pre-delay 0.5` |
| Toggle/switch | `sim-use tap @N --duration 0.05 --device <UDID>` (UISwitch needs a brief hold) |
| Swipe | `sim-use swipe --from 50,500 --to 350,500 --device <UDID>` |
| Pinch zoom in | `sim-use gesture pinch-out --device <UDID>` (two-finger spread) |
| Rotate | `sim-use gesture rotate-cw --angle 90 --device <UDID>` |

## 2. Pitfalls

Quick symptom index — see `references/pitfalls.md` for detailed recipes.

| Symptom | Cause | Fix |
|---|---|---|
| `tap --label` hits wrong element | Label collision (e.g. header and tab bar share text) | Add `--frame minY=0.7r` or `--element-type` to narrow |
| `tap @N` fails after navigation | Alias cache is stale | Re-run `ui` before tapping |
| `App:` line shows wrong app | System layer (alert, share sheet) is on top | Dismiss it first, then re-run `ui` |
| `multipleMatches` error | Several elements share the selector | Use `--frame`, `--element-type`, or a more specific selector |
| Tap lands but nothing happens | Animation in progress, or element not yet interactive | Add `--pre-delay 0.3` or `--wait-timeout 3` |
| iOS: `paste` drops text | Soft keyboard only; HID Cmd+V is ignored | Use `paste --via-menu --target-id <id>` |
| Android: `paste` denied | Background clipboard access blocked | Use `type` instead |
| Real device: `tap --label` feels slow (~2–4 s, more with `--wait-timeout`) | Live selectors fetch a fresh accessibility snapshot per resolution (and per poll tick) — that walk is expensive on a real phone | Expected. Prefer `@N` / `#N` aliases right after `ui` (instant, cache-backed); reserve selectors for scripted flows and transitions |
| Real device: every verb fails with "no bridge session" / "session has ended" | The XCUITest session stopped (host process killed, phone rebooted, cable pulled) | `sim-use ios-device status`, then `sim-use ios-device init` to restart it |
| Real device: `init` fails with "device is locked" | iOS refuses to launch a test runner on a locked device | Ask the user to unlock the phone; for long sessions set Auto-Lock to Never |
| Compose Multiplatform app: a field's text is missing from `AXValue` | Compose exposes text-field contents as `AXLabel`; `AXValue` stays nil | Read `AXLabel` — sim-use's own clear/verify paths already check both |
| Real device: `paste` exits non-zero saying the text didn't reach the field | Expected in most apps — iOS does not apply synthesized Cmd+V on real hardware (not a keyboard or alert problem) | The text **is** on the pasteboard. Use `type` for keyboard-producible text, or `paste --clipboard-only` if you only meant to stage it |
| Real device: an "Allow Paste" alert appears, or the pasted text is not what you staged | Some system surfaces (e.g. Spotlight) do honour Cmd+V and raise the iOS paste-consent alert; on a Mac-paired device Universal Clipboard may deliver the *Mac's* clipboard instead of the staged text | The alert is in `describe-ui` — tap Allow/Don't-Allow like any button, then verify the field with `ui` before trusting the content |
| Real device: `keyboard-state` says `soft (bounds unknown …)` | A third-party keyboard extension is active; it runs out-of-process so its bounds aren't readable | The keyboard *is* up — just don't rely on the occlusion y-value; verify tap targets with `ui` instead |
| Real device: `record-video` says the device is not visible as a screen-capture device | Either it is not on USB (CoreMediaIO cannot see Wi-Fi phones), another app holds it, or **macOS refuses this device model/OS pairing** for screen capture | Ask the user to plug in the cable and approve the one-time camera prompt. If it still fails, have them check QuickTime → New Movie Recording: if the phone is missing there too, the Mac cannot record it at all — fall back to `screenshot`, or ask the user to record from the device's own Control Center |
| Outline shows `U+FFFC` in label | iOS icon placeholder character | Match with `--label-regex` excluding the prefix |
| `[i] … covers ~N% of the screen` warning (text output, or `--json` top-level `advisory` key) | The selector resolved to a near-full-screen wrapper (common on Flutter/canvas UIs) and the tap hit its center, likely missing the intended control | Re-run `ui` and target the control via `@N`/`#<id>`, or pass explicit `-x/-y`/`--point` |
| `[i] Screen orientation could not be confirmed…` / `…coordinates may be stale…` advisory | Device/app is rotated (the `App:` header shows a tag like `(landscape-right)`) and orientation self-calibration couldn't verify the mapping, or the `@N` snapshot predates a rotation | Re-run `ui` and tap again; selectors handle rotation automatically once calibration succeeds. Explicit `-x/-y`/`--point` is always device-native portrait space |

## 3. Crash awareness

See `references/crash-awareness.md` for the full protocol. Summary:

sim-use watches for the target process disappearing between commands. When it detects a crash:

```
================ PROCESS DISAPPEARED ================
com.example.app (pid 12345) was alive at the previous command and is GONE now.
```

On Android, `ui` also detects the AOSP system crash dialog directly from the accessibility tree.

**Mandatory response:**
1. **STOP.** Do not silently relaunch or continue.
2. Report the crash to the user with the banner text.
3. Wait for instructions before proceeding.

After an intentional relaunch, call `sim-use app-state --reset` to clear the signal.

## 4. Escalation

Stop and ask the user when:
- A selector collision cannot be resolved with available disambiguators.
- Preflight fails and autofix does not recover.
- The task requires a destructive action (deleting data, uninstalling an app).
- You've retried the same action 3 times without progress.

## 5. Exit checklist

Before reporting a task as complete:
1. Run `sim-use ui` (or `screenshot`) to capture the final state.
2. Confirm the screen matches the intended outcome.
3. If the outcome is ambiguous, show the final `ui` output or screenshot to the user.
