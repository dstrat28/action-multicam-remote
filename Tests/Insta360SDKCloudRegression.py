import importlib.util
import io
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import unittest
from unittest import mock
import urllib.error
import zipfile

spec = importlib.util.spec_from_file_location("sdk_cloud", Path(__file__).resolve().parents[1] / "ci_scripts/insta360_sdk_cloud.py")
sdk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk)


class SDKCloudTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.vendor = self.root / "Vendor/Insta360"
        self.override = self.vendor / "Build.xcconfig"
        self.environment = {"CI_XCODE_CLOUD": "TRUE", "MULTICAM_INSTA360_SDK_ENABLED": "YES",
                            "INSTA360_SDK_URL": "https://private.invalid/sdk.zip?signature=secret"}
        self.archive = self.root / "sdk.zip"
        with zipfile.ZipFile(self.archive, "w") as archive:
            for name in sdk.FRAMEWORKS:
                binary = zipfile.ZipInfo(f"Frameworks/{name}.framework/{name}")
                binary.external_attr = (stat.S_IFREG | 0o755) << 16
                archive.writestr(binary, b"handwritten test fixture")
                archive.writestr(f"Frameworks/{name}.framework/Info.plist", b"fixture")
                archive.writestr(f"Frameworks/{name}.framework/PrivacyInfo.xcprivacy", b"fixture privacy")
        self.environment["INSTA360_SDK_SHA256"] = sdk.sha256(self.archive)

    def configure_with_archive(self):
        def download_fixture(url, token, destination):
            destination.write_bytes(self.archive.read_bytes())
        with mock.patch.object(sdk, "download", side_effect=download_fixture):
            sdk.configure(self.root, self.environment)

    def test_disabled_clears_override_and_does_not_download(self):
        self.vendor.mkdir(parents=True)
        self.override.write_text("MULTICAM_INSTA360_SDK_ENABLED = YES")
        self.environment.pop("MULTICAM_INSTA360_SDK_ENABLED")
        with mock.patch.object(sdk, "download") as download:
            sdk.configure(self.root, self.environment)
            download.assert_not_called()
        self.assertFalse(self.override.exists())

    def test_verified_archive_installs_resources_modes_and_enables_build(self):
        self.configure_with_archive()
        self.assertIn("MULTICAM_INSTA360_SDK_ENABLED = YES", self.override.read_text())
        for name in sdk.FRAMEWORKS:
            framework = self.vendor / "Frameworks" / f"{name}.framework"
            self.assertEqual((framework / "PrivacyInfo.xcprivacy").read_bytes(), b"fixture privacy")
            self.assertTrue((framework / name).stat().st_mode & stat.S_IXUSR)

    def test_missing_settings_and_bad_flag_fail(self):
        for key, value in (("INSTA360_SDK_SHA256", ""), ("INSTA360_SDK_URL", ""), ("MULTICAM_INSTA360_SDK_ENABLED", "true")):
            with self.subTest(key=key):
                environment = dict(self.environment, **{key: value})
                with self.assertRaises(ValueError), mock.patch.object(sdk, "download") as download:
                    sdk.configure(self.root, environment)
                download.assert_not_called()
                self.assertFalse(self.override.exists())

    def test_bad_checksum_removes_previous_override(self):
        self.vendor.mkdir(parents=True)
        self.override.write_text("MULTICAM_INSTA360_SDK_ENABLED = YES")
        self.environment["INSTA360_SDK_SHA256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.configure_with_archive()
        self.assertFalse(self.override.exists())

    def test_missing_framework_fails_before_install(self):
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("Frameworks/INSCameraSDK.framework/INSCameraSDK", "fixture")
        self.environment["INSTA360_SDK_SHA256"] = sdk.sha256(self.archive)
        with self.assertRaisesRegex(ValueError, "Missing device framework"):
            self.configure_with_archive()
        self.assertFalse(self.override.exists())
        self.assertFalse((self.vendor / "Frameworks").exists())

    def test_unexpected_paths_and_symlinks_are_rejected(self):
        for path in ("../outside", "/Frameworks/INSCameraSDK.framework/file", "Frameworks/../outside",
                     "Frameworks/other.framework/file", "Frameworks/INSCameraSDK.framework/link"):
            with self.subTest(path=path):
                with zipfile.ZipFile(self.archive, "w") as archive:
                    entry = zipfile.ZipInfo(path)
                    if path.endswith("link"):
                        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(entry, "outside")
                with self.assertRaises(ValueError):
                    sdk.unpack(self.archive, self.root / "unpacked")

    def test_download_uses_auth_and_redacts_failure(self):
        with mock.patch.object(sdk.urllib.request, "build_opener") as opener:
            opener.return_value.open.side_effect = urllib.error.URLError(self.environment["INSTA360_SDK_URL"])
            with self.assertRaises(ValueError) as error:
                sdk.download(self.environment["INSTA360_SDK_URL"], "secret-token", self.root / "download.zip")
            request = opener.return_value.open.call_args[0][0]
            self.assertEqual(request.get_header("Authorization"), "Bearer secret-token")
            self.assertEqual(request.get_header("Accept"), "application/octet-stream")
            self.assertNotIn("signature=secret", str(error.exception))
            self.assertNotIn("secret-token", str(error.exception))
        with self.assertRaises(ValueError):
            sdk.download("http://private.invalid/sdk.zip", "", self.root / "download.zip")

    def test_redirects_require_https_and_strip_cross_host_auth(self):
        handler = sdk.HTTPSRedirects()
        request = sdk.urllib.request.Request("https://private.invalid/sdk", headers={"Authorization": "Bearer secret"})
        redirected = handler.redirect_request(request, None, 302, "", {}, "https://storage.invalid/sdk")
        self.assertIsNone(redirected.get_header("Authorization"))
        with self.assertRaises(ValueError):
            handler.redirect_request(request, None, 302, "", {}, "http://storage.invalid/sdk")

    def test_package_round_trip_excludes_build_override(self):
        sdk.unpack(self.archive, self.vendor)
        self.override.write_text("MULTICAM_INSTA360_SDK_ENABLED = YES")
        packed = self.root / "packed.zip"
        with mock.patch("sys.stdout", new=io.StringIO()):
            sdk.package(self.vendor, packed)
        with zipfile.ZipFile(packed) as archive:
            self.assertNotIn("Build.xcconfig", archive.namelist())
        sdk.unpack(packed, self.root / "round-trip")

    def test_archive_validation_checks_linkage_resources_and_signatures(self):
        app = self.root / "build.xcarchive/Products/Applications/Multicam.app"
        sdk.unpack(self.archive, app)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Multicam"}))
        dependencies = "\n".join(f"@rpath/{name}.framework/{name}" for name in sdk.FRAMEWORKS)
        with mock.patch.object(sdk.subprocess, "check_output", return_value=dependencies), mock.patch.object(sdk.subprocess, "run") as codesign:
            sdk.verify_archive(self.root / "build.xcarchive")
            self.assertEqual(codesign.call_count, 4)
            (app / "Frameworks/INSCoreMedia.framework/PrivacyInfo.xcprivacy").unlink()
            with self.assertRaisesRegex(ValueError, "privacy manifest"):
                sdk.verify_archive(self.root / "build.xcarchive")
        with mock.patch.object(sdk.subprocess, "check_output", return_value=""):
            with self.assertRaisesRegex(ValueError, "embedded/linked"):
                sdk.verify_archive(self.root / "build.xcarchive")

    def run_prebuild(self, **updates):
        environment = dict(os.environ, CI_XCODE_CLOUD="TRUE", CI_PRIMARY_REPOSITORY_PATH=str(self.root))
        environment.pop("CI_BUILD_NUMBER", None)
        environment.update(updates)
        return subprocess.run(["/bin/sh", str(Path(sdk.__file__).with_name("ci_pre_xcodebuild.sh"))],
                              env=environment, text=True, capture_output=True)

    def test_prebuild_fails_for_enabled_workflow_without_secrets(self):
        result = self.run_prebuild(MULTICAM_INSTA360_SDK_ENABLED="YES", INSTA360_SDK_URL="", INSTA360_SDK_SHA256="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SDK-enabled workflow requires", result.stderr)

    def test_prebuild_clears_disabled_override_without_build_number(self):
        self.vendor.mkdir(parents=True)
        self.override.write_text("MULTICAM_INSTA360_SDK_ENABLED = YES")
        result = self.run_prebuild(MULTICAM_INSTA360_SDK_ENABLED="NO")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.override.exists())
        self.assertIn("leaving CURRENT_PROJECT_VERSION unchanged", result.stdout)

    def test_test_runner_skips_provisioning_without_source_or_secrets(self):
        result = self.run_prebuild(CI_XCODEBUILD_ACTION="test-without-building", MULTICAM_INSTA360_SDK_ENABLED="YES",
                                   CI_PRIMARY_REPOSITORY_PATH=str(self.root / "no-source-checkout"))
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
