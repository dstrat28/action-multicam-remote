# Insta360 iOS SDK Bluetooth control

Device builds that include the approved iOS v1.11.3 package automatically use
the SDK for its documented camera models. Ace and GO models retain GPS Remote
control. SDK-free builds retain the existing X5/X6 direct Bluetooth and GPS
Remote implementations. There is no user-facing backend setting.

## Private SDK installation and build

Install the vendor's original four-framework delivery:

- `INSCameraSDK.framework`
- `INSCameraServiceSDK.framework`
- `INSCoreMedia.framework`
- `SSZipArchive.framework`

Install the approved download locally:

```sh
sh ci_scripts/setup_insta360_sdk.sh /path/to/INSCameraSDKSample-bluetooth
```

The installer validates all four device binaries before copying their `ios-arm64`
frameworks, resources, and privacy manifests into `Vendor/Insta360/Frameworks`.
It omits the sample app, sample models, and debug-symbol bundles. The SDK-enabled
app links and embeds only `INSCameraServiceSDK` (about 9.2 MB before signing) for
Bluetooth control. Its Mach-O load commands reference only system libraries.
The unused preview/stitching/export chain (`INSCameraSDK` → `INSCoreMedia` →
`SSZipArchive`) stays out of the app, saving roughly 161 MB. Normal builds do not
include the SDK.

`Vendor/Insta360/` and framework bundles are ignored by Git. CI rejects tracked
vendor distribution files. The public repository contains our integration and
handwritten test doubles, not vendor binaries, headers, or sample implementation.
The repository's MIT license does not cover the vendor SDK.

```sh
xcodebuild \
  -project ActionCamRemote.xcodeproj \
  -scheme ActionCamRemote \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/multicam-insta360-sdk-device-dd \
  MULTICAM_INSTA360_SDK_ENABLED=YES \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For installation, configure signing as described in [CONTRIBUTING.md](../CONTRIBUTING.md).
`INSTA360_SDK_ROOT` can override the installed directory; it must contain the
`Frameworks` directory described above. Device builds with the option enabled
link/embed only the service framework, use `TO_B_SDK=1`, retain its resources/privacy
manifest, and sign it when signing is enabled. The embed step removes stale media
frameworks from reused build output. Disabling the build option removes all four
frameworks. The build phase retains all four output declarations so sandboxed
SDK-free builds can clean the previous bundle too.

SDK-enabled device builds also merge `NSCameraUsageDescription` into the app's
Info.plist. Apple's processing checks require it because the linked SDK contains
camera-access APIs, even though this integration's Bluetooth commands do not
request the phone/tablet camera. Its description states that distinction without
claiming an app feature that uses the phone camera. Standard and simulator builds
omit this SDK-specific purpose string. The original Info.plist keys are retained.

The supplied Camera/Media frameworks have no simulator slice. Simulator and
SDK-free device builds exclude SDK imports and binaries. A successful public
CI build therefore does not validate SDK packaging;
the SDK-enabled device build must also be checked locally with the approved files.
The current public GitHub CI workflow deliberately does not download the proprietary
package. It tests the Cloud provisioning code using handwritten fixtures.

### Xcode Cloud

Xcode Cloud runs `ci_scripts/ci_pre_xcodebuild.sh` before each build, analyze, or
archive action. The hook provisions the approved SDK privately when the workflow
opts in, then retains the existing Cloud build-number update. Test-without-building
actions reuse compiled products and skip provisioning because they lack the checkout.
No post-clone script or globally installed third-party tools are required.

Prepare the private device archive after the local install above:

```sh
python3 ci_scripts/insta360_sdk_cloud.py package \
  "$PWD/Vendor/Insta360/insta360-ios-v1.11.3-device.zip"
```

The command includes only the four `Frameworks/*.framework` bundles, including
their headers, modules, resources, signatures, and supplied privacy manifests. It
prints the archive's SHA-256. It excludes sample code, debug symbols, and generated
build settings. Keep the archive in private storage; do not commit it or attach it
to a public GitHub release, PR, Actions artifact, or log.

In the **release workflow's Environment** settings in Xcode or App Store Connect, set:

| Variable | Value | Secret |
| --- | --- | --- |
| `MULTICAM_INSTA360_SDK_ENABLED` | `YES` | No |
| `INSTA360_SDK_URL` | Authenticated HTTPS download URL for the private archive | Yes |
| `INSTA360_SDK_SHA256` | SHA-256 printed by the package command | No |
| `INSTA360_SDK_AUTH_TOKEN` | Optional read-only bearer token, if the download endpoint requires one | Yes |

A signed download URL can replace the bearer token, but must remain valid for
future builds. Redirects must stay on HTTPS; bearer tokens are not forwarded to a
different host. Download errors never print the URL or token. The embed build phase
also suppresses environment-variable logging. Keep these credentials scoped to a
trusted release workflow, without start conditions that run untrusted PR code.
Public PR checks need no SDK credentials.

Recommended hosting: a **separate private GitHub repository**, with the ZIP attached
to a versioned release. This keeps it out of the public source repository and avoids
adding another hosting service. Use the authenticated asset API URL
`https://api.github.com/repos/OWNER/PRIVATE_REPO/releases/assets/ASSET_ID` for
`INSTA360_SDK_URL`, and a fine-grained token limited to **Contents: read** on that
private repository for `INSTA360_SDK_AUTH_TOKEN`. The downloader requests the asset's
binary content and follows GitHub's download redirect without forwarding the token
to the storage host. Do not store the temporary redirect URL. Verify the repository
is private before uploading any SDK files. See GitHub's
[release asset API](https://docs.github.com/en/rest/releases/assets).

The hook verifies the archive checksum, validates all four bundles before installing,
and writes ignored `Vendor/Insta360/Build.xcconfig` to enable the device build. Both
app configurations include it through `ci_scripts/Insta360SDK.xcconfig`. Merely
exporting an environment variable would not override a target's project setting;
the generated configuration makes the workflow flag effective. Credentials are
never written to the generated configuration or the app bundle.
Downloads request uncached binary content. If a response fails the pinned checksum,
the download is attempted up to three times with short delays; only a matching response can be
installed. A final mismatch reports byte count and SHA-256 without logging private
URLs, tokens, or response contents.

If the workflow opts in but its URL, checksum, or frameworks are missing/invalid,
the build fails instead of silently producing an SDK-free release. Leaving the
flag unset or setting `NO` removes any generated override and builds the existing
routes. Simulator builds always omit the vendor SDK. SDK-enabled releases select
the backend automatically; an old saved opt-in preference has no effect.

The hooks and a local reproduction are checked in. Provision the private
archive and workflow variables separately for your release environment; the public
repository contains no private endpoint or credentials. Run a signed Cloud archive
and verify the result before distributing the first SDK-enabled release. The post-build hook
checks the actual archive for the linked/embedded service framework, its signature,
the supplied service privacy manifest, and the required camera purpose string. It
rejects unused media frameworks or a service update that links them.
This verifies Cloud download/signing, which local unsigned builds cannot establish.
Vendor debug symbols are not included in this compact dependency archive, so
symbolication inside the vendor's prebuilt binaries requires their matching dSYMs
separately. The app's own dSYM is generated normally.

Apple documents the hook lifecycle in
[Writing custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts)
and secret workflow variables in
[Xcode Cloud workflow reference](https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference).

The sample initializes the SDK camera manager before Bluetooth use. The supplied
`INSCameraManager.h` directs initialization through an explicit USB/socket manager
instead of its legacy shared accessor. Our Bluetooth integration initializes the
explicit USB manager when the first SDK client starts and shuts it down when the
last client closes. Bluetooth capture/status commands always use each camera's
own command interface. Wi-Fi and external-accessory controls are not used.

## Automatic camera routing

SDK-enabled device builds select the backend from the documented model list:

| Models | Backend |
| --- | --- |
| X6, X5, X4 Air, X4, X3, X2/ONE X2, ONE X, ONE R, ONE RS, ONE RS 1-Inch | Insta360 SDK Bluetooth |
| Ace/Ace Pro/Ace Pro 2, GO 3/3S/Ultra | Existing GPS Remote |
| Unknown models | Unavailable |

There is no Settings toggle, and the old saved SDK preference is ignored.
An established connection or in-flight handshake keeps its current backend,
including while recording. A new connection resolves the backend automatically.
SDK connection or capture failures never trigger a legacy connection or shutter
toggle. A remembered X5 GPS Remote fallback cannot override SDK selection.

For development or diagnosis, build with `MULTICAM_INSTA360_SDK_ENABLED=NO`.
This retains the existing X5/X6 direct Bluetooth and GPS Remote routes, including
a remembered X5 fallback. X2, ONE X, ONE R, and ONE RS 1-Inch have no legacy route
and remain unavailable in SDK-free builds. A backend change clears queued capture
intents rather than carrying them into a different protocol. SDK files continue
to come from private storage; automatic routing does not change public-repository
exclusion or Cloud provisioning.

## Camera and command scope

The complete official iOS list uses the SDK: X6, X5, X4 Air, X4, X3, X2, ONE X,
ONE R, ONE RS, and ONE RS 1-Inch. Ace and GO models retain GPS Remote control.
Eligibility is not physical-camera validation. Discovery also recognizes the
ONE X2 alias and ONE RS 1-Inch 360 Edition name.
In SDK-free builds, SDK-only models remain unavailable and never prepare a
GPS Remote restoration request. X5/X6 retain their existing direct control paths;
automatic routing does not remove those legacy implementations.

- Each camera has its own Bluetooth manager, device, command interface,
  connection task, delegate generation, and command confirmation state.
- Implements explicit video Start/Stop, normal Photo, normal Video/Photo mode
  changes, capture status, elapsed time, battery, and storage. Mode reads use
  successful `photoSubMode`/`videoSubMode` options: normal capture is 0 and the
  inactive family is 100. Legacy EVO sync-mode commands are not used.
- X6 requests `storageStateList` and reports its internal and SD storage
  in separate Camera Info rows, with free-space-only values. Capacities are not combined or
  presented as a selected recording volume. Other cameras use `storageStatus`.
- A common-run-loop timer ticks command deadlines every half second.
  Bluetooth uses per-device capture/mode polling, about once per second; the
  `sendHeartbeats` API documented for socket use is not called. Battery/storage refresh
  every 30 seconds and expire after 75; only successful fields are applied.
- Start, Photo, and mode changes require stopped status no older than five seconds.
  Start requires normal Video; Photo requires normal Photo. Explicit Stop remains
  available with unknown status. Stop can supersede pending capture/mode confirmation.
- SDK acceptance does not confirm Start, Stop, or a mode change. A subsequent
  query must match the command and follow its acceptance. Old/superseded replies
  cannot refresh state or complete another command. Slow mode replies retain
  the original capture observation's age. Confirmation expires after 25 seconds.
- Our adapter never repeats a capture call automatically. Disconnect cancels
  connection work, stops timers/observations, invalidates late SDK callbacks,
  fails pending commands, and clears telemetry. Missing status closes the session
  after 30 seconds. SDK failures do not switch routes or send shutter toggles.
- Transport selection, errors, and command outcomes appear in Diagnostics.
  Global SDK notifications without a reliable camera identity are not applied;
  status is requested through the specific device's interface.

Preview, media transfer, firmware updates, Wi-Fi setup, wake, advanced capture
modes, and highlight tags are outside this Bluetooth integration.

## Verification and remaining uncertainty

`sh ci_scripts/check_insta360_sdk.sh` tests state freshness, command confirmation,
late replies, mode gates, timeouts, automatic routing for all ten models,
connection-scoped backend ownership, legacy model eligibility, and return to a
remembered X5 route in SDK-free builds. SDK failures retain SDK routing on reconnect.

`sh ci_scripts/check_insta360_sdk_adapter.sh` exercises the actual adapter against
our handwritten SDK double: initialization/shutdown, independent cameras,
commands, pre-command replies, late connection/delegate callbacks, status
polling during UI tracking, X6 storage selection, and disconnect cleanup.
The double provides no evidence that vendor internals or camera firmware behave
identically. Native device builds verify the supplied headers and linker inputs.

No physical Insta360 camera is available for this review. Merge readiness is
based on documented setup, native builds, synthetic regression tests, and the
legacy routes remaining available in SDK-free builds. Camera
compatibility remains unverified and should be assessed through controlled user
reports in TestFlight for one-camera capture, multiple/mixed cameras, relaunch, Bluetooth loss,
and foreground/background transitions. Do not label a camera hardware-tested
without observing it physically.

References: supplied v1.11.3 headers and Bluetooth sample;
[iOS SDK overview](https://github.com/Insta360Develop/Insta360-Developer_Docs/blob/main/docs/en/sdk/x-ace-go/ios/guide.md),
[API reference](https://github.com/Insta360Develop/Insta360-Developer_Docs/blob/main/docs/en/sdk/x-ace-go/ios/api.md).

Optional battery/storage queries have independent request identities and a five-second display deadline. Capture-status polling takes priority and continues while optional metadata is delayed. An expired response is ignored and only one vendor telemetry request remains outstanding until it completes or the connection ends; capture commands are never repeated because of metadata failure. Metadata retains its 30-second refresh cadence.
