#!/bin/sh
set -eu

task_repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$task_repo_root"
task_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/multicam-carplay-controller.XXXXXX")
trap 'rm -rf "$task_test_dir"' 0

# Only this host executable sees the template/store doubles. The app continues
# compiling the same controller against Apple's real CarPlay framework.
xcrun swiftc \
  -emit-library -emit-module -module-name CarPlay \
  -module-cache-path "$task_test_dir/ModuleCache" \
  Tests/Support/CarPlay.swift \
  -emit-module-path "$task_test_dir/CarPlay.swiftmodule" \
  -o "$task_test_dir/libCarPlay.dylib" \
  -Xlinker -install_name -Xlinker @rpath/libCarPlay.dylib

xcrun swiftc \
  -parse-as-library \
  -module-cache-path "$task_test_dir/ModuleCache" \
  -I "$task_test_dir" -L "$task_test_dir" -lCarPlay \
  -Xlinker -rpath -Xlinker "$task_test_dir" \
  ActionCamRemote/Models/CameraModels.swift \
  ActionCamRemote/Bluetooth/Insta360RemoteProtocol.swift \
  ActionCamRemote/CarPlay/CarPlayCameraState.swift \
  ActionCamRemote/CarPlay/CarPlayCameraController.swift \
  Tests/CarPlayCameraControllerRegression.swift \
  -o "$task_test_dir/carplay-controller-regression"

"$task_test_dir/carplay-controller-regression"
