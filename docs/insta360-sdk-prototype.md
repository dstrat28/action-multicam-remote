# Insta360 iOS SDK Bluetooth prototype

PR #15 contains an opt-in device build using the approved iOS v1.11.3 package.
Normal builds retain the existing X5/X6 direct Bluetooth and GPS Remote backends.
The Settings preference `experimentalInsta360SDKEnabled` defaults to false.

## Build locally

The supplied `INSCameraSDKSample-bluetooth/Frameworks` directory contains the
Bluetooth implementation in `INSCameraServiceSDK.xcframework`. Its public
`INSBluetoothManager`, `INSBluetoothDevice`, and `INSCameraBasicCommands` APIs
provide the control operations used here. Binary dependency inspection and a
device build verify that this adapter does not need `INSCameraSDK`, `INSCoreMedia`,
`SSZipArchive`, the sample UI frameworks, or the sample's machine learning models.

Install the approved binary locally:

```sh
sh ci_scripts/setup_insta360_sdk.sh /path/to/INSCameraSDKSample-bluetooth
```

`Vendor/Insta360/` is ignored by Git. Vendor binaries, headers, and sample code
are not committed or downloaded by CI. `check_vendor_sdk_exclusion.sh` rejects
tracked framework bundles and vendor SDK distribution paths in CI. Other approved developers must install
their own package. The repository's MIT license does not cover the vendor SDK.

Build with the optional device configuration:

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
`INSTA360_SDK_ROOT` can override the installed directory. The optional build links,
embeds, and signs only `INSCameraServiceSDK.framework`, with `TO_B_SDK=1`.
The supplied camera framework has only an `ios-arm64` slice. Simulator builds
exclude the adapter and binary, and hide the Settings switch, including
when `MULTICAM_INSTA360_SDK_ENABLED=YES` is passed. Ordinary device builds also
hide the switch and do not link or embed the SDK. SDK device builds show the
**Insta360 SDK** switch without explanatory subtext.

In an SDK device build, turn on **Settings > Insta360 SDK**, then restart Multicam.
Selection is captured at app startup. Changing the preference never switches a
live connection or sends a shutter command. Turning it off and restarting restores
the existing backend, including a remembered X5 GPS Remote fallback.

## Implemented scope

- The complete official iOS SDK list is eligible: X6, X5, X4 Air, X4, X3, X2,
  ONE X, ONE R, ONE RS, and ONE RS 1-Inch. Ace and GO models retain GPS Remote
  control. Eligibility is not hardware validation.
- X2, ONE X, ONE R, and ONE RS 1-Inch require the enabled SDK backend. They are
  not routed to GPS Remote in ordinary builds or when the SDK preference is off.
  Discovery recognizes the ONE X2 alias and the ONE RS 1-Inch 360 Edition name;
  model-specific advertisements and control still require hardware verification.
- Each camera owns a separate vendor Bluetooth manager, device, command interface,
  connection task, generation token, and command confirmation state. The global
  current-camera singleton is never used.
- Explicit video Start/Stop, normal Photo capture, normal Video/Photo mode changes,
  capture status, elapsed time, battery, and active storage are implemented.
  Current mode is resolved from successfully returned `photoSubMode` and
  `videoSubMode`: normal capture is 0 and the inactive family is 100. Legacy
  EVO synchronization-mode commands are not used.
- A common-run-loop timer sends the sample's half-second heartbeats. Status/mode
  queries run serially, about once per second; battery/storage refresh every 30
  seconds and expire after 75. Only successful option fields are applied.
- Start, Photo, and mode changes require a stopped observation no older than five
  seconds. Start requires confirmed normal Video mode; Photo requires normal
  Photo mode. Unsupported modes remain unknown. Explicit Stop is allowed with
  unknown status. Stop can supersede an outstanding Start confirmation.
- SDK command acceptance alone does not confirm Start, Stop, or a mode change.
  A subsequent status query must match the command. Pre-command and superseded
  replies cannot refresh state or complete another command. A 25-second timeout
  fails confirmation without retrying capture commands.
- Disconnects cancel connection work, stop timers/observations, fail pending
  commands, invalidate late callbacks, and clear telemetry. A missing status
  callback closes the SDK session after 30 seconds. SDK failures never switch
  automatically to GPS Remote or send a toggle.
- SDK transport selection, failures, and command completion appear in Diagnostics.
  Unscoped global SDK capture notifications are not applied to any camera; status
  is requested through the specific device's command interface.

Preview, media transfer, firmware updates, Wi-Fi setup, wake, advanced capture
modes, highlight tags, and settings other than normal capture mode are outside
this Bluetooth prototype.

## Validation and remaining hardware work

`sh ci_scripts/check_insta360_sdk.sh` runs synthetic host regressions for status
freshness, mode gates, command confirmation, stale responses, Stop superseding
Start, timeouts, failures, disconnects, and independent cameras. Existing protocol
regressions still exercise the default backends. A build and synthetic tests do
not establish compatibility with physical cameras.

Before release, verify one camera's repeated start/stop, photos, mode changes, and
telemetry; then two supported Insta360 cameras together and a mixed
GoPro/DJI/Insta360 group. Check background/foreground transitions, app relaunch
while recording, Bluetooth loss, unsupported cameras, and returning to the default
backend after disabling the experiment. Keep PR #15 a draft until these results
are recorded.

References: the supplied v1.11.3 headers and Bluetooth sample;
[iOS SDK overview](https://github.com/Insta360Develop/Insta360-Developer_Docs/blob/main/docs/en/sdk/x-ace-go/ios/guide.md),
[API reference](https://github.com/Insta360Develop/Insta360-Developer_Docs/blob/main/docs/en/sdk/x-ace-go/ios/api.md).
