# Multicam

Native iPhone, iPad, and Apple Watch app for controlling multiple action cameras over Bluetooth.

Multicam is built for simultaneous multi-camera capture control. On iPhone and iPad, it can pair remembered cameras, reconnect to available cameras, select which cameras should be controlled, switch capture modes, take photos, and start or stop recording across selected cameras. The Apple Watch app shows connected cameras and can start or stop recording and add highlight markers. While recording, a Live Activity provides status plus Stop and Highlight controls on the Lock Screen and Dynamic Island.

[Download Action Multicam Remote on the App Store](https://apps.apple.com/us/app/action-multicam-remote/id6784017391).

GoPro support is built on the public Open GoPro BLE API. DJI Action/360/Nano support is experimental and based on DJI's R SDK demo plus observed BLE/DUML behavior. GoPro HERO13 Black and DJI Osmo Action 5 Pro, Action 6, and Nano have been tested directly; other documented Open GoPro BLE cameras, DJI Action 4, and DJI Osmo 360 are enabled as compatible but untested.

DJI Osmo Action 4, Action 5 Pro, Action 6, and Osmo 360 can optionally receive GPS telemetry from the iPhone for recording metadata and DJI Mimo dashboard overlays. The app sends location, altitude, direction, and speed while the camera is connected. This path has been verified end to end with an Action 6; Action 4, Action 5 Pro, and Osmo 360 remain unverified for phone GPS.

Multicam is an independent project and is not affiliated with, endorsed by, or sponsored by GoPro, DJI, or their affiliates.

## Status

This is an early hardware-driven project. The app currently targets iOS 17+ and watchOS 10+, using CoreBluetooth, WatchConnectivity, ActivityKit, and SwiftUI.

## App Store

App Store link: https://apps.apple.com/us/app/action-multicam-remote/id6784017391

Release and TestFlight setup notes live in [`docs/testflight.md`](docs/testflight.md).

| Camera | Compatibility | Testing |
| --- | --- | --- |
| GoPro HERO13 Black | Compatible | Tested |
| GoPro LIT HERO, MAX 2, HERO12 Black, HERO11 Black Mini, HERO11 Black, HERO10 Black, HERO9 Black | Compatible | Untested |
| DJI Osmo Action 4 | Compatible | Untested |
| DJI Osmo Action 5 Pro | Compatible | Tested |
| DJI Osmo Action 6 | Compatible | Tested |
| DJI Osmo 360 | Compatible | Untested |
| DJI Osmo Nano | Compatible | Tested |
| DJI Osmo Pocket 3 | Not supported | Tested |
| GoPro HERO, MAX, HERO8 Black; DJI Osmo Action 3, Action 2, and original Osmo Action | Not supported | Untested |

## What Works

- Pair and remember cameras.
- Show remembered cameras as Connected, Connecting, or Not Connected.
- Select cameras for multicam control.
- Start all selected cameras.
- Stop all selected recording cameras.
- Switch capture modes and take photos on compatible cameras.
- View available connection, battery, charging, recording, capture mode, camera settings, storage, and remaining-media information.
- Add a synchronized highlight tag to every compatible recording GoPro and DJI Action 4, Action 5 Pro, or Action 6 camera.
- Individually start/stop each camera.
- View connected cameras and start/stop all ready cameras or add a recording highlight from Apple Watch.
- Show recording status and elapsed time in a recording-only Live Activity, with Stop and Highlight controls on the Lock Screen and Dynamic Island.
- Optionally send iPhone GPS, altitude, direction, and speed to connected DJI Action 4/5/6 and Osmo 360 cameras for recording metadata.
- Keep diagnostic BLE logs collapsed unless needed for hardware debugging.

## Known Limits

- DJI support is experimental and may vary by firmware.
- DJI highlight tagging uses the R SDK QS-button key report and does not return an acknowledgement; verify the markers on non-critical footage before relying on it.
- GoPro HiLight tagging uses the public Open GoPro BLE command and is available only while the camera is recording.
- Phone GPS requires When In Use location permission and the iPhone app to remain open and connected while recording. Recorded video files contain precise location telemetry when this option is enabled.
- Capture-mode switching is available for compatible GoPro cameras and DJI Action 4/5/6 and Osmo 360 cameras. DJI Action 4 and Osmo 360 remain untested, Osmo Nano mode is display-only, and capture-setting editing is not exposed.
- DJI Action 4/5/6 and Osmo 360 require a completed R SDK handshake before control commands are sent; legacy recording fallbacks are retained only for Osmo Nano.
- DJI Osmo Nano sleep wake may be possible over BLE, but local testing was buggy enough that the app treats sleeping DJI cameras as Not Connected instead of Available.
- GoPro HERO13 Black is tested directly. Other documented Open GoPro BLE cameras are enabled as compatible but untested.
- Sleeping GoPros are shown as Not Connected and do not offer Wake. They auto-connect after being powered on.
- DJI Osmo Action 4, Action 5 Pro, Action 6, and Osmo 360 are shown as Not Connected while sleeping and do not offer Wake. DJI's official R SDK wake procedure broadcasts `WKP` plus the camera MAC for two seconds; iOS does not expose the raw BLE advertising and MAC access needed to replicate it.
- DJI cameras auto-connect when their protocol confirms they are awake. Because Action 4/5/6 and Osmo 360 may continue advertising while asleep, passive BLE probes remain hidden and the card stays Not Connected until that confirmation arrives.
- Osmo 360 follows DJI's official R SDK demo and the shared Action 4/5/6 profile but remains untested on local hardware.
- Action 4 follows DJI's documented support and the shared Action 5 profile but remains untested on local hardware.
- DJI Osmo Pocket 3 is intentionally disabled for now. It appears to require DJI Mimo's Bluetooth plus Wi-Fi control path rather than the BLE-only path this app uses for simultaneous multicam control.
- Apple Watch commands are relayed through the paired iPhone; the Watch does not connect directly to cameras.
- The app does not provide live preview or media browsing. Those workflows usually require Wi-Fi and are outside the current Bluetooth-first scope.
- iOS Simulator cannot connect to physical Bluetooth cameras; use a real iPhone or iPad for hardware testing.

## Build

Requirements:

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
- `docs/compatibility.md`: protocol notes, status, and next proof gates.

## Safety

The DJI adapter sends experimental BLE commands for supported Action/Nano cameras. Test with non-critical footage first, keep camera firmware differences in mind, and expect command/status behavior to change across device models or firmware revisions.

## License

MIT. See `LICENSE`.
