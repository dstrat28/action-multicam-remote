# Insta360 iOS SDK prototype

The 1.2.2 release is on `develop` and `main`. This work is separate from that release.

## Current state

Settings contains an **Insta360 SDK** switch marked experimental. Its stored preference,
`experimentalInsta360SDKEnabled`, defaults to false. The switch is disabled while
`FeatureAvailability.insta360SDK` is false. No SDK binaries or adapter are included;
camera control continues through the existing GPS Remote implementation.

This is preparation for the SDK prototype, not a working SDK integration. Do not
enable the availability flag until the adapter is implemented and verified.

## Required package

Apply for the iOS Camera SDK at <https://www.insta360.com/sdk/apply>. The public
repository contains documentation, not the framework package. The current guide
lists `INSCoreMedia.xcframework`, `INSCameraServiceSDK.xcframework`,
`INSCameraSDK.xcframework`, and `SSZipArchive.xcframework`, with `TO_B_SDK=1`.
Inspect the supplied headers, sample project, supported architectures, and
distribution instructions before adding the approved package to the project.

## Integration scope once the package is available

- Use the SDK's Bluetooth manager and per-peripheral command managers. Keep
  one session per camera; avoid routing multicamera commands through a global
  current-camera singleton.
- Start with the X-series models present in both our model list and the iOS
  support list: X6, X5, X4 Air, X4, X3, and ONE RS. Keep Ace and GO models on the
  existing GPS Remote backend unless Insta360 confirms iOS SDK support.
- Route explicit recording start/stop, photo capture, current mode, battery,
  and storage status through the SDK adapter. Register observations and send
  the documented heartbeats. Handle disconnects and command failures explicitly.
- Apply the setting to a camera when establishing its connection. Require an
  idle camera before changing backends; never send a shutter command or switch
  backend automatically during a recording.
- Keep preview, media transfer, firmware updates, and Wi-Fi setup outside this
  Bluetooth control prototype.
- Expose SDK transport selection, errors, and command results in diagnostics.

## Validation before enabling the switch

Verify one camera's repeated start/stop and telemetry first, then two supported
cameras together and a mixed GoPro/DJI/Insta360 group. Check background/foreground
transitions, app relaunch, Bluetooth loss, unsupported cameras, and a return to
GPS Remote control after disabling the experiment. A settings preference or a
successful simulator build does not establish camera compatibility.

Sources: [iOS SDK overview](https://github.com/Insta360Develop/Insta360-Developer_Docs/blob/main/docs/en/sdk/x-ace-go/ios/guide.md),
[API reference](https://github.com/Insta360Develop/Insta360-Developer_Docs/blob/main/docs/en/sdk/x-ace-go/ios/api.md).
