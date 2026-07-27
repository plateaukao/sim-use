#!/usr/bin/env bash

# The FB* frameworks are statically linked into the sim-use binary since the
# idb bump, so the release payload is the executable plus the two SwiftPM
# resource bundles — no Frameworks/ directory ships.
copy_release_payload() {
  local source_dir="$1"
  local destination_dir="$2"

  if [[ ! -f "${source_dir}/sim-use" ]]; then
    echo "❌ Error: sim-use executable missing from ${source_dir}" >&2
    exit 1
  fi

  if [[ ! -d "${source_dir}/SimUse_SimUse.bundle" ]]; then
    echo "❌ Error: sim-use resource bundle missing from ${source_dir}" >&2
    exit 1
  fi

  # AndroidBackend's resource bundle ships the bundled device-bridge APK
  # that `sim-use android init` pushes to the device. Without it the
  # brew-installed binary can't bootstrap Android support and surfaces
  # "Bridge APK not found in module bundle" at runtime. The bundle is
  # produced by `scripts/build.sh executable` → `copy_all_resource_bundles`,
  # which in turn requires `scripts/build-bridge.sh` to have refreshed
  # Sources/AndroidBackend/Resources/sim-use-device-bridge.apk first.
  if [[ ! -d "${source_dir}/SimUse_AndroidBackend.bundle" ]]; then
    echo "❌ Error: SimUse_AndroidBackend.bundle missing from ${source_dir}" >&2
    echo "   This usually means scripts/build-bridge.sh did not run before swift build." >&2
    echo "   Run scripts/build-bridge.sh and then re-stage." >&2
    exit 1
  fi

  # iOSDeviceBackend's resource bundle ships the on-device bridge's Xcode
  # project. Unlike the Android APK there is nothing prebuilt to ship —
  # an XCUITest runner must be signed with the user's own team, so
  # `sim-use ios-device init` builds it locally from these sources.
  # Without the bundle the brew-installed binary surfaces "could not find
  # the iOS bridge project" the first time anyone points it at a real
  # iPhone. Produced by `scripts/build.sh executable` →
  # `copy_all_resource_bundles`, which needs `scripts/build-ios-bridge.sh`
  # to have staged Sources/iOSDeviceBackend/Resources/ios-bridge first.
  if [[ ! -d "${source_dir}/SimUse_iOSDeviceBackend.bundle" ]]; then
    echo "❌ Error: SimUse_iOSDeviceBackend.bundle missing from ${source_dir}" >&2
    echo "   This usually means scripts/build-ios-bridge.sh did not run before swift build." >&2
    echo "   Run scripts/build-ios-bridge.sh and then re-stage." >&2
    exit 1
  fi

  rm -rf "$destination_dir"
  mkdir -p "$destination_dir"
  cp "$source_dir/sim-use" "$destination_dir/"
  cp -R "$source_dir/SimUse_SimUse.bundle" "$destination_dir/"
  cp -R "$source_dir/SimUse_AndroidBackend.bundle" "$destination_dir/"
  cp -R "$source_dir/SimUse_iOSDeviceBackend.bundle" "$destination_dir/"
}
