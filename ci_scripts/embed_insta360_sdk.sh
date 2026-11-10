#!/bin/sh
set -eu
if [ "${MULTICAM_INSTA360_SDK_ENABLED:-NO}" != YES ] || [ "$PLATFORM_NAME" != iphoneos ]; then
  # A reused build directory must not retain the optional binary after disabling it.
  for task_name in INSCameraServiceSDK INSCameraSDK INSCoreMedia SSZipArchive; do
    rm -rf "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/$task_name.framework"
  done
  exit 0
fi
for task_name in INSCameraServiceSDK; do
  test -f "$INSTA360_SDK_ROOT/Frameworks/$task_name.framework/$task_name" || {
    echo "error: Install the approved Insta360 package with ci_scripts/setup_insta360_sdk.sh first (missing $task_name)." >&2
    exit 1
  }
done
# Reused build products may still contain the former preview/media SDK chain.
for task_name in INSCameraSDK INSCoreMedia SSZipArchive; do
  rm -rf "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/$task_name.framework"
done
mkdir -p "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
for task_name in INSCameraServiceSDK; do
  task_source="$INSTA360_SDK_ROOT/Frameworks/$task_name.framework"
  task_destination="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/$task_name.framework"
  rm -rf "$task_destination"
  /usr/bin/ditto "$task_source" "$task_destination"
  rm -rf "$task_destination/Headers" "$task_destination/Modules"
  if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata=identifier,entitlements "$task_destination"
  fi
done
