#!/bin/sh
set -eu
task_repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$task_repo_root"
task_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/multicam-insta360-sdk-adapter.XXXXXX")
trap 'rm -rf "$task_test_dir"' 0
for task_module in CoreBluetooth INSCameraServiceSDK; do
  if [ "$task_module" = CoreBluetooth ]; then task_source=Tests/Support/CoreBluetooth.swift; else task_source=Tests/Support/Insta360SDK.swift; fi
  xcrun swiftc -emit-library -emit-module -module-name "$task_module" \
    -module-cache-path "$task_test_dir/ModuleCache" "$task_source" \
    -emit-module-path "$task_test_dir/$task_module.swiftmodule" \
    -o "$task_test_dir/lib$task_module.dylib" \
    -Xlinker -install_name -Xlinker "@rpath/lib$task_module.dylib"
done
xcrun swiftc -parse-as-library -D INSTA360_SDK -module-cache-path "$task_test_dir/ModuleCache" \
  -I "$task_test_dir" -L "$task_test_dir" -lCoreBluetooth -lINSCameraServiceSDK \
  -Xlinker -rpath -Xlinker "$task_test_dir" \
  ActionCamRemote/Models/CameraModels.swift \
  ActionCamRemote/Bluetooth/Insta360RemoteProtocol.swift \
  ActionCamRemote/Bluetooth/BLECameraDeviceClient.swift \
  ActionCamRemote/Bluetooth/Insta360SDKSession.swift \
  ActionCamRemote/Bluetooth/Insta360SDKClient.swift \
  Tests/Insta360SDKAdapterRegression.swift -o "$task_test_dir/adapter-regression"
"$task_test_dir/adapter-regression"
