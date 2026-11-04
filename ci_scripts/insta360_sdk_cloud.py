#!/usr/bin/env python3
"""Prepare a private device SDK archive or provision it before Xcode Cloud builds."""

import hashlib
import http.client
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

FRAMEWORKS = ("INSCameraSDK", "INSCameraServiceSDK", "INSCoreMedia", "SSZipArchive")
REPO_ROOT = Path(__file__).resolve().parent.parent


def validate_frameworks(root):
    for name in FRAMEWORKS:
        framework = root / "Frameworks" / f"{name}.framework"
        if not (framework / name).is_file() or not (framework / "Info.plist").is_file():
            raise ValueError(f"Missing device framework: {name}. Run setup_insta360_sdk.sh first.")


def package(root, output):
    validate_frameworks(root)
    if output.resolve().is_relative_to((root / "Frameworks").resolve()):
        raise ValueError("Write the archive outside the Frameworks directory.")
    # Do not package Build.xcconfig, sample code, debug symbols, or other local files.
    with zipfile.ZipFile(output, "x", zipfile.ZIP_DEFLATED) as archive:
        for name in FRAMEWORKS:
            for path in sorted((root / "Frameworks" / f"{name}.framework").rglob("*")):
                if path.is_symlink():
                    raise ValueError("Device frameworks must not contain symbolic links.")
                if path.is_file() and path.name != ".DS_Store":
                    archive.write(path, path.relative_to(root).as_posix())
    print(f"Private SDK archive prepared: {output}")
    print(f"INSTA360_SDK_SHA256={sha256(output)}")
    print("Keep this archive private; do not attach it to a public release or PR.")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class HTTPSRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        if urllib.parse.urlsplit(new_url).scheme != "https":
            raise ValueError("Private SDK downloads must remain on HTTPS.")
        redirected = super().redirect_request(request, response, code, message, headers, new_url)
        if redirected and urllib.parse.urlsplit(request.full_url).netloc != urllib.parse.urlsplit(new_url).netloc:
            redirected.remove_header("Authorization")
        return redirected


def download(url, token, destination):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or not parts.hostname or parts.username or parts.password:
        raise ValueError("INSTA360_SDK_URL must be a private HTTPS URL without embedded credentials.")
    headers = {"Accept": "application/octet-stream"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        request = urllib.request.Request(url, headers=headers)
        with urllib.request.build_opener(HTTPSRedirects()).open(request, timeout=120) as response:
            with destination.open("wb") as output:
                shutil.copyfileobj(response, output)
    except (urllib.error.URLError, OSError, ValueError, http.client.HTTPException):
        # URLs may be signed, so never print the URL, token, or raw exception.
        raise ValueError("Private SDK download failed; check the workflow's URL/access and expiry.") from None


def unpack(archive_path, destination):
    with zipfile.ZipFile(archive_path) as archive:
        entries = archive.infolist()
        seen = set()
        for entry in entries:
            parts = PurePosixPath(entry.filename).parts
            if (entry.filename in seen or ".." in parts or "\\" in entry.filename
                    or not parts or parts[0] != "Frameworks"
                    or (len(parts) == 1 and not entry.is_dir())
                    or (len(parts) > 1 and parts[1] not in {f"{name}.framework" for name in FRAMEWORKS})
                    or stat.S_ISLNK(entry.external_attr >> 16)):
                raise ValueError("Unexpected entry in private SDK archive; use the package command.")
            seen.add(entry.filename)
        for entry in entries:
            target = Path(archive.extract(entry, destination))
            if not entry.is_dir():
                target.chmod((entry.external_attr >> 16) & 0o777 or 0o644)
    validate_frameworks(destination)


def configure(repo_root, environ):
    if environ.get("CI_XCODE_CLOUD") != "TRUE":
        raise ValueError("The configure command is only for Xcode Cloud's pre-build hook.")
    root = repo_root / "Vendor" / "Insta360"
    override = root / "Build.xcconfig"
    # A failed reconfiguration must never leave a previously enabled override.
    override.unlink(missing_ok=True)
    enabled = environ.get("MULTICAM_INSTA360_SDK_ENABLED", "NO")
    if enabled not in ("YES", "NO"):
        raise ValueError("MULTICAM_INSTA360_SDK_ENABLED must be YES or NO.")
    if enabled == "NO":
        print("Xcode Cloud: building without the optional Insta360 SDK.")
        return
    url = environ.get("INSTA360_SDK_URL", "")
    expected = environ.get("INSTA360_SDK_SHA256", "")
    if not url or not re.fullmatch(r"[0-9a-fA-F]{64}", expected):
        raise ValueError("SDK-enabled workflow requires secret INSTA360_SDK_URL and pinned INSTA360_SDK_SHA256.")
    with tempfile.TemporaryDirectory(prefix="multicam-private-sdk-") as temporary:
        staging = Path(temporary)
        archive = staging / "sdk.zip"
        download(url, environ.get("INSTA360_SDK_AUTH_TOKEN", ""), archive)
        if sha256(archive) != expected.lower():
            raise ValueError("Private SDK checksum mismatch; refusing to enable the SDK build.")
        unpack(archive, staging / "unpacked")
        root.mkdir(parents=True, exist_ok=True)
        shutil.rmtree(root / "Frameworks", ignore_errors=True)
        shutil.copytree(staging / "unpacked" / "Frameworks", root / "Frameworks")
    override.write_text("// Generated after private SDK verification; never commit.\nMULTICAM_INSTA360_SDK_ENABLED = YES\n")
    print("Xcode Cloud: verified and installed all four private frameworks; SDK build enabled.")


def verify_archive(archive, verify_signatures=True):
    apps = list((archive / "Products/Applications").glob("*.app"))
    if len(apps) != 1:
        raise ValueError("Expected one iOS app in the Cloud archive.")
    app = apps[0]
    with (app / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if not info.get("NSCameraUsageDescription", "").strip():
        raise ValueError("SDK-enabled archive needs NSCameraUsageDescription for the SDK's linked camera APIs.")
    executable = info["CFBundleExecutable"]
    dependencies = subprocess.check_output(["xcrun", "otool", "-L", str(app / executable)], text=True)
    for name in FRAMEWORKS:
        framework = app / "Frameworks" / f"{name}.framework"
        if not (framework / name).is_file() or f"@rpath/{name}.framework/{name}" not in dependencies:
            raise ValueError(f"SDK-enabled Cloud archive is missing embedded/linked {name}.")
        if name in ("INSCameraServiceSDK", "INSCoreMedia") and not (framework / "PrivacyInfo.xcprivacy").is_file():
            raise ValueError(f"Cloud archive is missing {name}'s supplied privacy manifest.")
        if verify_signatures:
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(framework)], check=True)
    print("Verified all four SDK frameworks and supplied privacy manifests in the archive.")


def main():
    if sys.argv[1:] == ["configure"]:
        configure(Path(os.environ.get("CI_PRIMARY_REPOSITORY_PATH", REPO_ROOT)), os.environ)
    elif len(sys.argv) == 3 and sys.argv[1] == "package":
        package(REPO_ROOT / "Vendor" / "Insta360", Path(sys.argv[2]))
    elif sys.argv[1:] == ["verify"] and os.environ.get("CI_ARCHIVE_PATH"):
        verify_archive(Path(os.environ["CI_ARCHIVE_PATH"]))
    else:
        raise ValueError("Usage: insta360_sdk_cloud.py package /private/path/sdk.zip | configure | verify (requires CI_ARCHIVE_PATH)")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
