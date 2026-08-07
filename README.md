# Multicam

Native iPhone, iPad, and Apple Watch app for controlling multiple action cameras over Bluetooth.

Pair and control multiple GoPro, DJI, and Insta360 cameras together. Start or stop recording, take photos, switch capture modes, and add highlight markers where supported from iPhone, iPad, or Apple Watch. A Live Activity keeps recording controls on the Lock Screen and Dynamic Island.

[Download Action Multicam Remote on the App Store](https://apps.apple.com/us/app/action-multicam-remote/id6784017391).

GoPro support uses the public Open GoPro BLE API. DJI support uses DJI's R SDK protocol and BLE/DUML behavior. Experimental Insta360 support emulates the Bluetooth GPS Remote protocol and does not use Wi-Fi. HERO13 Black, Osmo Action 5 Pro, Action 6, Osmo 360, and Osmo Nano have been tested directly.

Multicam is an independent project and is not affiliated with, endorsed by, or sponsored by GoPro, DJI, Insta360, or their affiliates.

## Camera Support

| Camera | Support | Hardware tested |
| --- | --- | --- |
| GoPro HERO13 Black | Supported | Yes |
| GoPro LIT HERO, MAX 2, HERO12 Black, HERO11 Black Mini, HERO11 Black, HERO10 Black, HERO9 Black | Supported | No |
| DJI Osmo Action 4 | Supported | No |
| DJI Osmo Action 5 Pro | Supported | Yes |
| DJI Osmo Action 6 | Supported | Yes |
| DJI Osmo 360 | Supported | Yes |
| DJI Osmo Nano | Supported | Yes |
| Insta360 Ace Pro 2, Ace Pro, Ace, X5, X4 Air, X4, X3, ONE RS | Experimental GPS Remote control | No |
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
- Control awake Insta360 cameras through an emulated GPS Remote connection. Recording status is confirmed from camera timer packets; mode changes use the remote's cycle command.

## Known Limitations

- Camera behavior can vary by model and firmware; see the hardware-testing status above.
- Insta360 support requires selecting `Insta360 GPS Remote` in the camera's Bluetooth Remote settings while Multicam remains open. iOS cannot broadcast the manufacturer-specific wake advertisement used by the physical remote, so sleeping-camera wake is not supported.
- Pair multiple Insta360 cameras one at a time. iOS does not expose an incoming camera's Bluetooth address, so Multicam assigns new GPS Remote subscriptions in the order connection requests were made.
- Insta360 GPS Remote control does not expose camera settings, battery/storage telemetry, highlight markers, preview, or media transfer. Mode changes are not acknowledged by the remote protocol and must be verified on the camera.
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
- [KonradIT/osmosis](https://github.com/KonradIT/osmosis) for DJI Osmo Nano DUML research and documentation.
- [rhoenschrat/DJI-Remote](https://github.com/rhoenschrat/DJI-Remote) for DJI highlight-tag research.
- [marcelpallares/insta360-m5stick-remote](https://github.com/marcelpallares/insta360-m5stick-remote) for the MIT-licensed Insta360 GPS Remote, Ace Pro 2/X5, multicamera, command, and recording-status reference implementation.
- [pchwalek/insta360_ble_esp32](https://github.com/pchwalek/insta360_ble_esp32) for the MIT-licensed CE80/CE81/CE82 GPS Remote service and command reference implementation.

## License

MIT. See `LICENSE`.
