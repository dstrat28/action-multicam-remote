#!/bin/sh
set -eu

task_scripts_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
# Test runners do not have the source checkout and reuse already-built products.
if [ "${CI_XCODEBUILD_ACTION:-}" = test-without-building ]; then
  exit 0
fi
if [ "${CI_XCODE_CLOUD:-}" = TRUE ]; then
  python3 "$task_scripts_dir/insta360_sdk_cloud.py" configure
fi

if [ -z "${CI_BUILD_NUMBER:-}" ]; then
  echo "CI_BUILD_NUMBER is not set; leaving CURRENT_PROJECT_VERSION unchanged."
  exit 0
fi

case "$CI_BUILD_NUMBER" in
  ''|*[!0-9]*)
    echo "CI_BUILD_NUMBER must be an integer, got: $CI_BUILD_NUMBER"
    exit 1
    ;;
esac

cd "${CI_PRIMARY_REPOSITORY_PATH:-.}"
echo "Setting CURRENT_PROJECT_VERSION to Xcode Cloud build number: $CI_BUILD_NUMBER"
xcrun agvtool new-version -all "$CI_BUILD_NUMBER"
