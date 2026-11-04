#!/bin/sh
set -eu
task_repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
task_source=${1:?Usage: sh ci_scripts/setup_insta360_sdk.sh /path/to/INSCameraSDKSample-bluetooth}
for task_name in INSCameraServiceSDK INSCameraSDK INSCoreMedia SSZipArchive; do
  test -f "$task_source/Frameworks/$task_name.xcframework/ios-arm64/$task_name.framework/$task_name" || {
    echo "Missing device $task_name in the approved SDK package." >&2
    exit 1
  }
done
# Keep just the device frameworks, including their resources and privacy files.
# The download's large debug-symbol bundles and sample assets are not needed.
mkdir -p "$task_repo_root/Vendor/Insta360/Frameworks"
for task_name in INSCameraServiceSDK INSCameraSDK INSCoreMedia SSZipArchive; do
  /usr/bin/ditto "$task_source/Frameworks/$task_name.xcframework/ios-arm64/$task_name.framework" \
    "$task_repo_root/Vendor/Insta360/Frameworks/$task_name.framework"
done
echo "Installed the four documented Insta360 dependencies locally. Build with MULTICAM_INSTA360_SDK_ENABLED=YES."
