#!/bin/sh
set -eu
task_repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
task_source=${1:?Usage: sh ci_scripts/setup_insta360_sdk.sh /path/to/INSCameraSDKSample-bluetooth}
for task_name in INSCameraServiceSDK INSCameraSDK INSCoreMedia SSZipArchive; do
  test -f "$task_source/Frameworks/$task_name.xcframework/ios-arm64/$task_name.framework/$task_name" &&
    test -f "$task_source/Frameworks/$task_name.xcframework/ios-arm64/$task_name.framework/Info.plist" || {
    echo "Missing device $task_name in the approved SDK package." >&2
    exit 1
  }
done
# Keep just the device frameworks, including their resources and privacy files.
# The download's large debug-symbol bundles and sample assets are not needed.
mkdir -p "$task_repo_root/Vendor/Insta360"
task_staging=$(mktemp -d "$task_repo_root/Vendor/Insta360/install.XXXXXX")
trap 'rm -rf "$task_staging"' EXIT HUP INT TERM
for task_name in INSCameraServiceSDK INSCameraSDK INSCoreMedia SSZipArchive; do
  /usr/bin/ditto "$task_source/Frameworks/$task_name.xcframework/ios-arm64/$task_name.framework" \
    "$task_staging/$task_name.framework"
done
# Replacing avoids retaining files from a previous SDK version. A local install
# also clears the Cloud-only build override; local builds still opt in explicitly.
rm -rf "$task_repo_root/Vendor/Insta360/Frameworks"
mv "$task_staging" "$task_repo_root/Vendor/Insta360/Frameworks"
rm -f "$task_repo_root/Vendor/Insta360/Build.xcconfig"
echo "Installed the four documented Insta360 dependencies locally. Build with MULTICAM_INSTA360_SDK_ENABLED=YES."
