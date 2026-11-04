#!/bin/sh
set -eu
task_repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
cd "$task_repo_root"
python3 - <<'PY'
import subprocess
import sys

paths = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
blocked = [path for path in paths if path and (
    path.startswith("Vendor/Insta360/")
    or any(part.endswith((".framework", ".xcframework")) for part in path.split("/"))
    or path.rsplit("/", 1)[-1] in {"INSCameraSDK", "INSCameraServiceSDK", "INSCoreMedia", "SSZipArchive"}
    or path.startswith(("iOS_v", "INSCameraSDKSample"))
)]
if blocked:
    print("Vendor SDK distribution files must remain local and untracked:", file=sys.stderr)
    print("\n".join(blocked), file=sys.stderr)
    sys.exit(1)
print("Vendor SDK exclusion check passed: no SDK distribution files are tracked.")
PY
