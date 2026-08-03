# Multicam

Native iPhone, iPad, and Apple Watch app for controlling multiple action cameras over Bluetooth.

Pair and control multiple GoPro and DJI cameras together. Start or stop recording, take photos, switch capture modes, and add highlight markers from iPhone, iPad, or Apple Watch. A Live Activity keeps recording controls on the Lock Screen and Dynamic Island.

[Download Action Multicam Remote on the App Store](https://apps.apple.com/us/app/action-multicam-remote/id6784017391).

GoPro support uses the public Open GoPro BLE API. DJI support uses DJI's R SDK protocol and BLE/DUML behavior. HERO13 Black, Osmo Action 5 Pro, Action 6, and Osmo Nano have been tested directly.

Multicam is an independent project and is not affiliated with, endorsed by, or sponsored by GoPro, DJI, or their affiliates.

## Camera Support

| Camera | Support | Hardware tested |
| --- | --- | --- |
| GoPro HERO13 Black | Supported | Yes |
| GoPro LIT HERO, MAX 2, HERO12 Black, HERO11 Black Mini, HERO11 Black, HERO10 Black, HERO9 Black | Supported | No |
| DJI Osmo Action 4 | Supported | No |
| DJI Osmo Action 5 Pro | Supported | Yes |
| DJI Osmo Action 6 | Supported | Yes |
| DJI Osmo 360 | Supported | No |
| DJI Osmo Nano | Supported | Yes |
| DJI Osmo Pocket 3 | Not supported | Yes |
| GoPro HERO, MAX, HERO8 Black; DJI Osmo Action 3, Action 2, original Osmo Action | Not supported | No |

## What Works

- Pair, remember, reconnect, and select cameras for group control.
- Start or stop all selected cameras, or control each one individually.
- Switch capture modes, take photos, and view camera, battery, storage, and recording status.
- Add synchronized highlight markers to recording GoPros and DJI Action 4/5/6 cameras.
- Control recording and highlights from Apple Watch or a Live Activity.
- Send optional iPhone GPS, altitude, direction, and speed telemetry to DJI Action 4/5/6 and Osmo 360 recordings.
- Wake paired GoPros for up to eight hours after sleep, and wake Osmo Nano over Bluetooth.

## Known Limitations

- Camera behavior can vary by model and firmware; see the hardware-testing status above.
- Wake is not supported on other DJI cameras because they require a manufacturer-data wake advertisement that iPhone apps cannot broadcast.
- Highlights are recording-only. DJI cameras do not acknowledge highlight commands, so verify markers before relying on them for critical footage.
- Phone GPS requires location permission and the iPhone app to remain open and connected. Enabling it writes precise location telemetry to recordings; the complete path has been tested on Action 6.
- Apple Watch commands pass through the paired iPhone; the Watch does not connect directly to cameras.
- Live preview and media browsing are not supported because they require Wi-Fi rather than the app's Bluetooth-first control path.
- Physical cameras cannot connect to iOS Simulator.

## Build

- Xcode 15 or newer.
- iOS 17 or newer deployment target.
- watchOS 10 or newer for the included Apple Watch app.
- A physical iPhone or iPad for camera testing.

Open `ActionCamRemote.xcodeproj` in Xcode, select the `ActionCamRemote` scheme, choose your signing team, then build and run on a device.

Command-line simulator build:

```sh
xcodebuild \
  -project ActionCamRemote.xcodeproj \
  -scheme ActionCamRemote \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Physical-device command-line builds require your own development team:

```sh
xcodebuild \
  -project ActionCamRemote.xcodeproj \
  -scheme ActionCamRemote \
  -destination 'platform=iOS,name=Your Device Name' \
  DEVELOPMENT_TEAM=YOURTEAMID \
  build
```

## Project Layout

- `ActionCamRemote/Models`: shared camera, command, capability, and result types.
- `ActionCamRemote/Bluetooth`: CoreBluetooth scanner plus brand-specific BLE clients.
- `ActionCamRemote/LiveActivity`: shared ActivityKit state, controller, and App Intents.
- `ActionCamRemote/Services`: app-level store/coordinator.
- `ActionCamRemote/UI`: SwiftUI app surfaces.
- `MulticamLiveActivity`: Lock Screen and Dynamic Island Live Activity extension.
- `MulticamWatchApp`: Apple Watch remote UI and WatchConnectivity session model.

## Acknowledgements

Thank you to these projects for helping make Multicam possible:

- [dji-sdk/Osmo-GPS-Controller-Demo](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo) for DJI's R SDK BLE, camera-control, status, and GPS reference implementation.
- [gopro/OpenGoPro](https://github.com/gopro/OpenGoPro) for GoPro's official BLE interface specification, documentation, and demos.
- [KonradIT/DJI-ESP32-Remote](https://github.com/KonradIT/DJI-ESP32-Remote) for Osmo Nano wake, pairing, and shooting-mode research.
- [rhoenschrat/DJI-Remote](https://github.com/rhoenschrat/DJI-Remote) for DJI highlight-tag research.

## License

MIT. See `LICENSE`.
