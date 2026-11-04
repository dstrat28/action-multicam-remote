#!/bin/sh
set -eu
task_repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
task_source=${1:?Usage: sh ci_scripts/setup_insta360_sdk.sh /path/to/INSCameraSDKSample-bluetooth}
task_framework="$task_source/Frameworks/INSCameraServiceSDK.xcframework"
test -f "$task_framework/ios-arm64/INSCameraServiceSDK.framework/INSCameraServiceSDK" || {
  echo "Missing device INSCameraServiceSDK in the supplied SDK package." >&2
  exit 1
}
mkdir -p "$task_repo_root/Vendor/Insta360"
/usr/bin/ditto "$task_framework" "$task_repo_root/Vendor/Insta360/INSCameraServiceSDK.xcframework"
echo "Installed local Insta360 Bluetooth framework. Build for iOS with MULTICAM_INSTA360_SDK_ENABLED=YES."
