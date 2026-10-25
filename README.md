# Multicam

Native iPhone, iPad, and Apple Watch app for controlling multiple action cameras over Bluetooth.

Pair and control multiple GoPro, DJI, and Insta360 cameras together. Start or stop recording, take photos, switch capture modes, and add highlight markers where supported from iPhone, iPad, or Apple Watch. A Live Activity keeps recording controls on the Lock Screen and Dynamic Island.

[Download Multicam on the App Store](https://apps.apple.com/us/app/action-multicam-remote/id6784017391).

GoPro support uses the public Open GoPro BLE API. DJI support uses DJI's R SDK protocol and BLE/DUML behavior. Experimental Insta360 support emulates the Bluetooth GPS Remote protocol and does not use Wi-Fi. HERO13 Black, Osmo Action 5 Pro, Action 6, Osmo 360, and Osmo Nano have been tested directly.

Multicam is an independent project and is not affiliated with, endorsed by, or sponsored by GoPro, DJI, Insta360, or their affiliates.

## Camera Support

| Camera | Support | Hardware Tested |
| --- | --- | --- |
| GoPro HERO13 Black | Yes | Yes |
| GoPro LIT HERO | Yes | No |
| GoPro MAX 2 | Yes | Yes |
| GoPro HERO12 Black | Yes | No |
| GoPro HERO11 Black Mini | Yes | No |
| GoPro HERO11 Black | Yes | No |
| GoPro HERO10 Black | Yes | No |
| GoPro HERO9 Black | Yes | No |
| DJI Osmo Action 4 | Yes | No |
| DJI Osmo Action 5 Pro | Yes | Yes |
| DJI Osmo Action 6 | Yes | Yes |
| DJI Osmo 360 | Yes | Yes |
| DJI Osmo Nano | Yes | Yes |
| Insta360 Ace Pro 2 | Experimental | No |
| Insta360 Ace Pro | Experimental | No |
| Insta360 Ace | Experimental | No |
| Insta360 X5 | Experimental | No |
| Insta360 X4 Air | Experimental | No |
| Insta360 X4 | Experimental | No |
| Insta360 X3 | Experimental | No |
| Insta360 ONE RS | Experimental | No |
| Insta360 GO Ultra | Experimental | No |
| Insta360 GO 3S | Experimental | No |
| Insta360 GO 3 | Experimental | No |
| Insta360 X6 | Experimental | No |
| DJI Osmo Pocket 3 | No | Yes |
| GoPro HERO | No | No |
| GoPro MAX | No | No |
| GoPro HERO8 Black | No | No |
| DJI Osmo Action 3 | No | No |
| DJI Action 2 | No | No |
| DJI Osmo Action (original) | No | No |

## What Works

- Pair, remember, reconnect, and select cameras for group control.
- Start or stop all selected cameras, or control each one individually.
- Switch capture modes, take photos, and view camera, battery, storage, and recording status.
- Add synchronized highlight markers to recording GoPros and DJI Action 4/5/6 cameras.
- Control recording and highlights from Apple Watch or a Live Activity.
- Send optional iPhone GPS, altitude, direction, and speed telemetry to DJI Action 4/5/6 and Osmo 360 recordings.
- Wake paired GoPros for up to eight hours after sleep, and wake Osmo Nano over Bluetooth.
- Control awake Insta360 cameras through an emulated GPS Remote connection. Valid camera timer packets indicate recording; missing or stale timers leave recording status unknown. The remote protocol provides a mode-cycle command.

## Known Limitations

- Camera behavior can vary by model and firmware; see the hardware-testing status above.
- Insta360 X6 is discoverable, but it does not accept the GPS Action Remote protocol that Multicam currently emulates.
- Insta360 support requires selecting `Insta360 GPS Remote` in the camera's Bluetooth Remote settings while Multicam remains open.
- Insta360 wake is experimental and has not been verified on hardware. Multicam attempts a targeted iBeacon advertisement while the app is in the foreground. iOS supports this fixed beacon format, but the ESP32 remote reference includes an extra byte that this format does not reproduce; successful wake must not be assumed.
- Insta360 recording and photo commands use the same shutter toggle in the camera's current mode. Recording state is inferred from timer packets, and an unknown state does not establish that the camera is stopped or in Video mode. Verify the camera's mode before using group recording. Bluetooth queues retain only the latest unsent command per camera for up to two seconds and discard it if the connection or observed recording state changes. Discarded commands are reported in Diagnostics and are not automatically retried.
- Pair multiple Insta360 cameras one at a time. iOS does not expose an incoming camera's Bluetooth address, so Multicam assigns new GPS Remote subscriptions in the order connection requests were made.
- Insta360 GPS Remote control does not expose camera settings, battery/storage telemetry, highlight markers, preview, or media transfer. Mode changes are not acknowledged by the remote protocol and must be verified on the camera.
- Wake is not supported on other DJI cameras because their `WKP` manufacturer-data wake advertisement cannot be reproduced through iOS's fixed iBeacon format or ordinary Core Bluetooth advertising.
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
- `ActionCamRemote/CarPlay`: paired-camera selection and video recording controls, awaiting Apple's entitlement approval.
- `ActionCamRemote/UI`: SwiftUI app surfaces.
- `MulticamLiveActivity`: Lock Screen and Dynamic Island Live Activity extension.
- `MulticamWatchApp`: Apple Watch remote UI and WatchConnectivity session model.

## CarPlay (Awaiting Entitlement Approval)

The CarPlay implementation is compiled into the iPhone app, but the restricted entitlement is **off by default**. Ordinary Debug, Release, and archive builds retain their existing signing requirements. Do not enable CarPlay signing or test the CarPlay interface until Apple approves the Driving Task request for `com.ds.ActionCamRemote` (team `2WX2Z9452K`).

The single CarPlay screen lists previously paired cameras with selection checkmarks, connection/recording status, and separate Start Recording and Stop Recording actions. It shares the iPhone's camera store, including on a CarPlay-first launch. Camera selection changes are shared with the iPhone. Start requires every selected camera to be connected, in confirmed Video mode, and confirmed ready/stopped; it does not take photos, change modes, or partially start a group. Stop affects selected cameras that are recording or starting, including the existing reconnect-and-stop path. Pairing and detailed settings remain on iPhone before the drive. Periodic CarPlay status refreshes occur at most once every 10 seconds; selections and commands refresh immediately.

Insta360 remote mode/status reporting can remain unknown. Such cameras cannot start recording through CarPlay until Video mode and stopped/ready state are known. A confirmed recording can still be stopped. Hardware validation is required for each supported brand.

After approval:

1. Enable **CarPlay Driving Task App** for this App ID in the developer portal and refresh the development/distribution provisioning profiles.
2. Build the iPhone target with `MULTICAM_CARPLAY_ENABLED=YES`. This selects `ActionCamRemote/CarPlay/MulticamCarPlay.entitlements` for that target only; Watch and Live Activity signing are unaffected. Set the user-defined setting on the iPhone target in Xcode, or pass it to `xcodebuild` for a dedicated build. Keep it off for builds that should not advertise CarPlay.
3. Use Apple's CarPlay Simulator with a physical iPhone to validate Bluetooth camera control. Xcode's iOS Simulator can validate templates with `--demo-connected-cameras`, but cannot connect to real cameras. Reuse the existing local simulator pool and hold `/tmp/trackside-ios-<UDID>.lock` for the entire install/UI session.
4. Verify CarPlay-first launch with iPhone locked, concurrent phone/CarPlay selection, selected-only Start/Stop, Start followed immediately by Stop, camera disconnect/reconnect during recording, empty/unsupported/photo/unknown-status states, CarPlay disconnect/reconnect, and each supported camera brand on a real head unit. Check that selecting/deselecting cameras never sends a shutter command and that Stop does not affect deselected cameras.

The host regression check runs without a CarPlay entitlement or simulator:

```sh
xcrun swiftc -parse-as-library \
  ActionCamRemote/Models/CameraModels.swift \
  ActionCamRemote/Bluetooth/Insta360RemoteProtocol.swift \
  ActionCamRemote/CarPlay/CarPlayCameraState.swift \
  Tests/CarPlayCameraStateRegression.swift \
  -o /tmp/multicam-carplay-regression
/tmp/multicam-carplay-regression
```

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
