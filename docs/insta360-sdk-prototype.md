# Insta360 iOS SDK Bluetooth control

PR #15 adds optional control using the approved iOS v1.11.3 package. SDK control
is off by default. Ordinary builds retain the existing X5/X6 direct Bluetooth
and GPS Remote implementations.

## Private SDK installation and build

Follow the vendor's four-framework dependency list:

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
app's unthinned dependencies occupy about 167 MB; normal builds do not include them.

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
link/embed all four frameworks, use `TO_B_SDK=1`, retain resource/privacy files,
and sign each embedded framework when signing is enabled. Disabling the build
option removes all four frameworks from reused build output.

The supplied Camera/Media frameworks have no simulator slice. Simulator and
ordinary device builds exclude SDK imports and binaries and hide the Settings
switch. A successful public CI build therefore does not validate SDK packaging;
the SDK-enabled device build must also be checked locally with the approved files.
Xcode Cloud/release builders need these dependencies supplied privately and
`MULTICAM_INSTA360_SDK_ENABLED=YES` to offer the setting to users. The current public
CI workflow deliberately does not download the proprietary package.

The sample initializes the SDK camera manager before Bluetooth use. The supplied
`INSCameraManager.h` directs initialization through an explicit USB/socket manager
instead of its legacy shared accessor. Our Bluetooth integration initializes the
explicit USB manager when the first SDK client starts and shuts it down when the
last client closes. Bluetooth capture/status commands always use each camera's
own command interface. Wi-Fi and external-accessory controls are not used.

## Setting and return to existing control

SDK device builds show a plain **Settings > Insta360 SDK** switch. Changes apply
to the next connection without restarting Multicam. An established connection or
an in-flight handshake keeps its current method, including while recording.

To return to existing control, turn the switch off, disconnect the camera, and
connect it again. The selection change clears queued capture intents; it does
not send a shutter command. A remembered X5 GPS Remote fallback is preserved.
X2, ONE X, ONE R, and ONE RS 1-Inch require SDK control and have no existing route
to return to; disabling SDK makes those four models unavailable.

## Camera and command scope

The complete official iOS list is eligible: X6, X5, X4 Air, X4, X3, X2, ONE X,
ONE R, ONE RS, and ONE RS 1-Inch. Ace and GO models retain GPS Remote control.
Eligibility is not physical-camera validation. Discovery also recognizes the
ONE X2 alias and ONE RS 1-Inch 360 Edition name.

- Each camera has its own Bluetooth manager, device, command interface,
  connection task, delegate generation, and command confirmation state.
- Implements explicit video Start/Stop, normal Photo, normal Video/Photo mode
  changes, capture status, elapsed time, battery, and storage. Mode reads use
  successful `photoSubMode`/`videoSubMode` options: normal capture is 0 and the
  inactive family is 100. Legacy EVO sync-mode commands are not used.
- X6 requests `storageStateList` and reports its internal and SD storage
  separately, as documented by the vendor. Capacities are not combined or
  presented as a selected recording volume. Other cameras use `storageStatus`.
- A common-run-loop timer sends half-second heartbeats as shown in the sample.
  Capture/mode queries are serial, about once per second. Battery/storage refresh
  every 30 seconds and expire after 75; only successful fields are applied.
- Start, Photo, and mode changes require stopped status no older than five seconds.
  Start requires normal Video; Photo requires normal Photo. Explicit Stop remains
  available with unknown status. Stop can supersede pending Start confirmation.
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
late replies, mode gates, timeouts, all ten models, connection-scoped preference
changes, and return to a remembered X5 route with SDK availability on and off.

`sh ci_scripts/check_insta360_sdk_adapter.sh` exercises the actual adapter against
our handwritten SDK double: initialization/shutdown, independent cameras,
commands, pre-command replies, late connection/delegate callbacks, half-second
heartbeats during UI tracking, X6 storage selection, and disconnect cleanup.
The double provides no evidence that vendor internals or camera firmware behave
identically. Native device builds verify the supplied headers and linker inputs.

No physical Insta360 camera is available for this review. Merge readiness is
based on documented setup, native builds, synthetic regression tests, the
existing routes remaining available, and SDK control being opt-in. Camera
compatibility remains unverified and should be assessed through controlled user
reports for one-camera capture, multiple/mixed cameras, relaunch, Bluetooth loss,
and foreground/background transitions. Do not label a camera hardware-tested
without observing it physically.

References: supplied v1.11.3 headers and Bluetooth sample;
[iOS SDK overview](https://github.com/Insta360Develop/Insta360-Developer_Docs/blob/main/docs/en/sdk/x-ace-go/ios/guide.md),
[API reference](https://github.com/Insta360Develop/Insta360-Developer_Docs/blob/main/docs/en/sdk/x-ace-go/ios/api.md).
