# Contributing

Thanks for helping make Multicam better.

## Development

Requirements:

- Xcode 26 or newer, including the iOS and watchOS SDKs.
- iOS 17 or newer deployment target.
- watchOS 10 or newer for the included Apple Watch app.
- A physical iPhone or iPad for Bluetooth camera testing.

The UI uses [Liquid Glass APIs from the Xcode 26 SDKs](https://developer.apple.com/videos/play/wwdc2025/323/) with runtime fallbacks for older supported iOS versions. Build the `ActionCamRemote` scheme. iOS Simulator can run the UI but cannot connect to real cameras.

```sh
xcodebuild \
  -project ActionCamRemote.xcodeproj \
  -scheme ActionCamRemote \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For signed device builds, use your own Apple development team and unique bundle identifiers for all three targets. Update the Watch app's `WKCompanionAppBundleIdentifier` to match the iPhone app. You do not need access to the publisher's team.

After configuring signing and identifiers in Xcode, a physical-device build without CarPlay can use:

```sh
xcodebuild \
  -project ActionCamRemote.xcodeproj \
  -scheme ActionCamRemote \
  -destination 'platform=iOS,name=Your Device Name' \
  DEVELOPMENT_TEAM=YOURTEAMID \
  MULTICAM_CARPLAY_ENABLED=NO \
  build
```

CarPlay is enabled by default for the published app's iPhone target. Set `MULTICAM_CARPLAY_ENABLED=NO` in the iPhone target's Build Settings or command-line build unless your own team and App ID have the Driving Task entitlement. Unsigned simulator builds can retain the default. See [CarPlay development](docs/carplay.md) for entitlement setup and testing; `sh ci_scripts/check_carplay_controller.sh` runs the host-side controller check without an entitlement or simulator.

## Hardware Reports

Camera behavior varies by model, firmware, and power state. Good reports include:

- camera model and firmware version;
- iOS/iPadOS version;
- whether the camera was on, asleep, or off;
- whether the app showed Connected, Available, or Not Connected;
- what command was sent;
- what happened on the physical camera;
- a diagnostics file from Settings > Diagnostics > Share if you are comfortable sharing it.

Recent diagnostic logs are saved locally across app restarts, up to 5 MB. The oldest entries are removed when the archive reaches its size limit. Share exports all retained logs as a text file, alongside current app, device, and camera details. Clear beside Bluetooth Log removes both the displayed and saved logs. Logging starts when the app runs; it cannot recover logs from before this archive was introduced.

Command Results saves up to 500 commands (512 KiB maximum) across app restarts, including later delivery outcomes for queued commands. Diagnostics shows the latest six results with timestamps; the exported file includes all retained results in a separate section. Reset beside Command Results clears saved commands independently of Bluetooth logs and camera controls. Simulator demos keep both histories in memory only.

Settings > Send Feedback prepares an email to multicam@dstrat.io with a fresh diagnostics report attached. When Mail is unavailable, the app offers to share the same file through another app. The user reviews and sends the email.

Review diagnostics before posting publicly. They may contain Bluetooth identifiers, camera names, service UUIDs, and raw command bytes.

## Protocol Work

GoPro changes should follow the public Open GoPro BLE API. DJI Action/360 control uses DJI's R SDK handshake and status protocol, with model-scoped DUML commands where behavior differs between cameras. Experimental Insta360 support emulates the Bluetooth GPS Remote protocol. See [camera support and protocol notes](docs/camera-support.md) for limitations.

Keep model-specific behavior isolated, preserve the shared connection flow, and include regression coverage for packet encoding or state parsing changes. Mark a camera as hardware-tested only after verifying it on a physical device.

The repository's bundle identifiers belong to the published app and do not grant access to its signing credentials.

## Project Layout

- `ActionCamRemote/Models`: shared camera, command, capability, and result types.
- `ActionCamRemote/Bluetooth`: CoreBluetooth scanner plus brand-specific BLE clients.
- `ActionCamRemote/LiveActivity`: shared ActivityKit state, controller, and App Intents.
- `ActionCamRemote/Services`: app-level store/coordinator.
- `ActionCamRemote/CarPlay`: paired-camera selection and video recording controls.
- `ActionCamRemote/UI`: SwiftUI app surfaces.
- `MulticamLiveActivity`: Lock Screen and Dynamic Island Live Activity extension.
- `MulticamWatchApp`: Apple Watch remote UI and WatchConnectivity session model.
