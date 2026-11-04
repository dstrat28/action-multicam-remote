#!/bin/sh
set -eu
task_repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$task_repo_root"
task_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/multicam-dji-stop.XXXXXX")
trap 'rm -rf "$task_test_dir"' 0
xcrun swiftc -emit-library -emit-module -module-name CoreBluetooth \
  -module-cache-path "$task_test_dir/ModuleCache" Tests/Support/CoreBluetooth.swift \
  -emit-module-path "$task_test_dir/CoreBluetooth.swiftmodule" \
  -o "$task_test_dir/libCoreBluetooth.dylib" \
  -Xlinker -install_name -Xlinker '@rpath/libCoreBluetooth.dylib'
xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" \
  -I "$task_test_dir" -L "$task_test_dir" -lCoreBluetooth \
  -Xlinker -rpath -Xlinker "$task_test_dir" \
  ActionCamRemote/Models/CameraModels.swift \
  ActionCamRemote/Bluetooth/Insta360RemoteProtocol.swift \
  ActionCamRemote/Bluetooth/BLECameraDeviceClient.swift \
  ActionCamRemote/Bluetooth/DJICommandTracker.swift \
  ActionCamRemote/Bluetooth/DJINanoProtocol.swift \
  ActionCamRemote/Bluetooth/DJIExperimentalBLEClient.swift \
  ActionCamRemote/Services/PhoneGPSProvider.swift \
  Tests/DJIStopFeedbackRegression.swift -o "$task_test_dir/dji-stop-regression"
"$task_test_dir/dji-stop-regression"
