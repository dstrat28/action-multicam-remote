#!/bin/sh
set -eu
task_repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$task_repo_root"
task_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/multicam-recording-work.XXXXXX")
trap 'rm -rf "$task_test_dir"' 0
for task_module in CoreBluetooth INSCameraServiceSDK UIKit; do
  if [ "$task_module" = INSCameraServiceSDK ]; then task_source=Tests/Support/Insta360SDK.swift;
  else task_source="Tests/Support/$task_module.swift"; fi
  xcrun swiftc -emit-library -emit-module -module-name "$task_module" \
    -module-cache-path "$task_test_dir/ModuleCache" "$task_source" \
    -emit-module-path "$task_test_dir/$task_module.swiftmodule" \
    -o "$task_test_dir/lib$task_module.dylib" \
    -Xlinker -install_name -Xlinker "@rpath/lib$task_module.dylib"
done
xcrun swiftc -parse-as-library -D INSTA360_SDK -module-cache-path "$task_test_dir/ModuleCache" \
  -I "$task_test_dir" -L "$task_test_dir" -lCoreBluetooth -lINSCameraServiceSDK -lUIKit \
  -Xlinker -rpath -Xlinker "$task_test_dir" \
  ActionCamRemote/Models/CameraStorageVolume.swift \
  ActionCamRemote/Models/CameraModels.swift \
  ActionCamRemote/Bluetooth/*.swift \
  ActionCamRemote/Services/CameraStore.swift \
  ActionCamRemote/Services/PreviewData.swift \
  ActionCamRemote/Services/DiagnosticLogArchive.swift \
  ActionCamRemote/Services/CommandResultArchive.swift \
  ActionCamRemote/Services/PhoneGPSProvider.swift \
  ActionCamRemote/CarPlay/CarPlayCameraState.swift \
  Tests/Support/CameraStoreHostSupport.swift \
  Tests/CameraStoreRecordingWorkRegression.swift -o "$task_test_dir/store-regression"
"$task_test_dir/store-regression"
