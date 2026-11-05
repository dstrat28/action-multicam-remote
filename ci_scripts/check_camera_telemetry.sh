#!/bin/sh
set -eu
task_repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$task_repo_root"
task_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/multicam-camera-telemetry.XXXXXX")
trap 'rm -rf "$task_test_dir"' 0
xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" \
  ActionCamRemote/Models/CameraModels.swift \
  ActionCamRemote/Bluetooth/Insta360RemoteProtocol.swift \
  Tests/CameraTelemetryRegression.swift -o "$task_test_dir/telemetry-regression"
"$task_test_dir/telemetry-regression"
