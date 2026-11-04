#!/bin/sh
set -eu
# Check the actual signed archive, independently of the requested build flag.
if [ "${CI_XCODE_CLOUD:-}" = TRUE ] &&
   [ "${CI_XCODEBUILD_ACTION:-}" = archive ] &&
   [ "${CI_XCODEBUILD_EXIT_CODE:-1}" = 0 ] &&
   [ "${MULTICAM_INSTA360_SDK_ENABLED:-NO}" = YES ]; then
  task_scripts_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
  python3 "$task_scripts_dir/insta360_sdk_cloud.py" verify
fi
