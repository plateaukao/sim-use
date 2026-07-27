#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Stages the iOS device-bridge project into the SwiftPM resource bundle so
# a released `sim-use` can build the runner on a user's machine.
#
# This is the iOS counterpart of `scripts/build-bridge.sh`, but it stages
# *sources*, not a built artifact. An Android APK can be prebuilt once and
# installed anywhere; an iOS test runner has to be signed by a team the
# target device trusts, so the build necessarily happens on the user's
# machine at `sim-use ios-device init` time.
#
# Usage:
#   scripts/build-ios-bridge.sh            # stage sources
#   scripts/build-ios-bridge.sh --check    # verify the toolchain only
#   scripts/build-ios-bridge.sh --compile  # stage + compile-check (Simulator SDK, no signing)
#   scripts/build-ios-bridge.sh --generate # regenerate the .xcodeproj from project.yml (needs xcodegen)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${REPO_ROOT}/ios-bridge"
DEST_DIR="${REPO_ROOT}/Sources/iOSDeviceBackend/Resources/ios-bridge"

MODE="stage"
for arg in "$@"; do
  case "$arg" in
    --check)    MODE="check" ;;
    --compile)  MODE="compile" ;;
    --generate) MODE="generate" ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

fail() { echo "❌ $*" >&2; exit 1; }
ok()   { echo "✅ $*"; }

check_toolchain() {
  command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found. Install Xcode (15 or newer)."
  local version
  version="$(xcodebuild -version | head -1)"
  ok "${version}"

  local major
  major="$(echo "$version" | sed -E 's/Xcode ([0-9]+).*/\1/')"
  if [[ -n "$major" && "$major" -lt 15 ]]; then
    fail "Xcode 15+ is required for real-device support (found ${version})."
  fi

  if command -v xcrun >/dev/null 2>&1 && xcrun devicectl --version >/dev/null 2>&1; then
    ok "devicectl available"
  else
    echo "⚠️  devicectl unavailable — `sim-use ios-device devices` will not find anything."
  fi

  if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    ok "Apple Development signing identity present"
  else
    echo "⚠️  No 'Apple Development' identity in the keychain. `ios-device init` will need --team-id"
    echo "   and a matching identity before it can build the runner."
  fi
}

generate_project() {
  command -v xcodegen >/dev/null 2>&1 || fail "xcodegen not found (brew install xcodegen). The committed .xcodeproj only needs regenerating when files are added or moved."
  (cd "$SOURCE_DIR" && xcodegen generate)
  ok "Regenerated ${SOURCE_DIR}/SimUseDeviceBridge.xcodeproj"
}

stage_sources() {
  [[ -d "$SOURCE_DIR" ]] || fail "Missing ${SOURCE_DIR}"
  [[ -d "${SOURCE_DIR}/SimUseDeviceBridge.xcodeproj" ]] || \
    fail "Missing ${SOURCE_DIR}/SimUseDeviceBridge.xcodeproj — run with --generate."

  mkdir -p "$(dirname "$DEST_DIR")"
  rm -rf "$DEST_DIR"
  # Exclude build detritus and per-user Xcode state: xcuserdata in
  # particular differs between machines and would make the staged copy
  # (and therefore the build cache key) churn for no reason.
  rsync -a \
    --exclude 'build/' \
    --exclude 'DerivedData/' \
    --exclude '*.xcuserdatad' \
    --exclude 'xcuserdata/' \
    --exclude '.DS_Store' \
    "${SOURCE_DIR}/" "${DEST_DIR}/"
  ok "Staged bridge sources → ${DEST_DIR#${REPO_ROOT}/}"
}

compile_check() {
  local simulator
  # Any installed iOS simulator runtime will do — this is a compile
  # check, nothing is ever run. Signing is disabled so it works in CI.
  simulator="$(xcrun simctl list devices available -j 2>/dev/null \
    | python3 -c 'import json,sys
data = json.load(sys.stdin)["devices"]
for runtime, devices in data.items():
    if "iOS" not in runtime: continue
    for device in devices:
        print(device["udid"]); raise SystemExit
' 2>/dev/null || true)"

  [[ -n "$simulator" ]] || fail "No iOS Simulator runtime installed; cannot compile-check the bridge."

  xcodebuild build-for-testing \
    -project "${SOURCE_DIR}/SimUseDeviceBridge.xcodeproj" \
    -scheme SimUseDeviceBridgeRunner \
    -destination "id=${simulator}" \
    -derivedDataPath "${REPO_ROOT}/.build/ios-bridge-check" \
    CODE_SIGNING_ALLOWED=NO \
    >/dev/null || fail "Bridge runner failed to compile."
  ok "Bridge runner compiles against the Simulator SDK"
}

case "$MODE" in
  check)    check_toolchain ;;
  generate) generate_project; stage_sources ;;
  compile)  check_toolchain; stage_sources; compile_check ;;
  stage)    stage_sources ;;
esac
