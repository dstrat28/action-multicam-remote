#!/bin/sh
set -eu
task_destination="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/INSCameraServiceSDK.framework"
if [ "${MULTICAM_INSTA360_SDK_ENABLED:-NO}" != YES ] || [ "$PLATFORM_NAME" != iphoneos ]; then
  # A reused build directory must not retain the optional binary after disabling it.
  rm -rf "$task_destination"
  exit 0
fi
task_source="$INSTA360_SDK_ROOT/INSCameraServiceSDK.xcframework/ios-arm64/INSCameraServiceSDK.framework"
if [ ! -f "$task_source/INSCameraServiceSDK" ]; then
  echo "error: Install the approved Insta360 package with ci_scripts/setup_insta360_sdk.sh first." >&2
  exit 1
fi
mkdir -p "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
/usr/bin/ditto "$task_source" "$task_destination"
rm -rf "$task_destination/Headers" "$task_destination/Modules"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata=identifier,entitlements "$task_destination"
fi
