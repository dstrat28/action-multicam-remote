#!/bin/sh
set -eu
task_repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$task_repo_root"
task_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/multicam-watch-telemetry.XXXXXX")
trap 'rm -rf "$task_test_dir"' 0
xcrun swiftc -emit-library -emit-module -module-name WatchConnectivity \
  -module-cache-path "$task_test_dir/ModuleCache" Tests/Support/WatchConnectivity.swift \
  -emit-module-path "$task_test_dir/WatchConnectivity.swiftmodule" \
  -o "$task_test_dir/libWatchConnectivity.dylib" \
  -Xlinker -install_name -Xlinker '@rpath/libWatchConnectivity.dylib'
xcrun swiftc -parse-as-library -D DEBUG -module-cache-path "$task_test_dir/ModuleCache" \
  -I "$task_test_dir" -L "$task_test_dir" -lWatchConnectivity \
  -Xlinker -rpath -Xlinker "$task_test_dir" \
  ActionCamRemote/Models/CameraStorageVolume.swift \
  ActionCamRemote/Models/CameraModels.swift \
  ActionCamRemote/Bluetooth/Insta360RemoteProtocol.swift \
  ActionCamRemote/Services/WatchConnectivityController.swift \
  MulticamWatchApp/WatchSessionModel.swift \
  Tests/WatchCameraTelemetryRegression.swift -o "$task_test_dir/watch-telemetry-regression"
"$task_test_dir/watch-telemetry-regression"
