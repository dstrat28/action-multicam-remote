# Multicam

Native iOS app for controlling multiple action cameras over Bluetooth.

Multicam is built for simultaneous multi-camera capture control. It can pair remembered cameras, reconnect to available cameras, select which cameras should be controlled, and start/stop recording across selected cameras.

[Download Action Multicam Remote on the App Store](https://apps.apple.com/us/app/action-multicam-remote/id6784017391).

GoPro support is built on the public Open GoPro BLE API. DJI Action/Nano support is experimental and based on observed BLE/DUML behavior because DJI does not publish an equivalent camera-control API for these cameras. GoPro HERO13 Black is tested directly; other documented Open GoPro BLE cameras are enabled as compatible but untested.

Multicam is an independent project and is not affiliated with, endorsed by, or sponsored by GoPro, DJI, or their affiliates.

## Status

This is an early hardware-driven project. The app currently targets iOS 17+ and uses CoreBluetooth plus SwiftUI.

## App Store

App Store link: https://apps.apple.com/us/app/action-multicam-remote/id6784017391

Release and TestFlight setup notes live in [`docs/testflight.md`](docs/testflight.md).

| Camera | Status | Notes |
| --- | --- | --- |
| GoPro HERO13 Black | Tested | BLE discovery, wake/connect, start/stop recording, recording status, model detection, and Video preset switching are implemented through Open GoPro BLE. |
| GoPro LIT HERO, MAX 2, HERO12 Black, HERO11 Black Mini, HERO11 Black, HERO10 Black, HERO9 Black | Compatible, untested | These models are listed in the public Open GoPro BLE API and use the same BLE client path. Model detection is enabled, but hardware behavior has not been verified locally. |
| DJI Osmo Action 6 | Tested, experimental | BLE connect, start/stop recording in Video mode, and recording-state reads are implemented. Sleep wake has not been observed to work over BLE. DJI mode/settings commands are not considered reliable. |
| DJI Osmo Nano | Tested, experimental | BLE connect, start/stop recording while connected, and recording status are implemented with Nano-specific state handling. Sleep wake may be possible over BLE, but local testing was too unreliable to expose it in the app. DJI mode/settings commands are not considered reliable. |
| DJI Osmo Pocket 3 | Not supported | The app recognizes Pocket 3 devices but disables pairing, selection, and record controls. Local testing found BLE status traffic, but no working BLE-only record command; DJI's documented phone-control path uses Bluetooth plus Wi-Fi. |
| Other cameras | Not supported | Cameras outside the tested DJI list or documented Open GoPro BLE list are shown as Unsupported until their BLE behavior is tested and mapped. |

## What Works

- Pair and remember cameras.
- Show remembered cameras as Connected, Available, or Not Connected.
- Select cameras for multicam control.
- Start all selected cameras.
- Stop all selected recording cameras.
- Individually start/stop each camera.
- Keep diagnostic BLE logs collapsed unless needed for hardware debugging.

## Known Limits

- DJI support is experimental and may vary by firmware.
- DJI mode switching and settings editing are intentionally limited until the BLE command mapping is proven.
- DJI recording should be started only when the camera is already in Video mode.
- DJI Osmo Nano sleep wake may be possible over BLE, but local testing was buggy enough that the app treats sleeping DJI cameras as Not Connected instead of Available.
- GoPro HERO13 Black is tested directly. Other documented Open GoPro BLE cameras are enabled as compatible but untested.
- Only DJI Osmo Action 6 and DJI Osmo Nano are currently enabled for DJI. Other DJI cameras are shown as Unsupported until tested.
- DJI Osmo Pocket 3 is intentionally disabled for now. It appears to require DJI Mimo's Bluetooth plus Wi-Fi control path rather than the BLE-only path this app uses for simultaneous multicam control.
- The app does not provide live preview or media browsing. Those workflows usually require Wi-Fi and are outside the current Bluetooth-first scope.
- iOS Simulator cannot connect to physical Bluetooth cameras; use a real iPhone or iPad for hardware testing.

## Build

Requirements:

- Xcode 15 or newer.
- iOS 17 or newer deployment target.
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
- `ActionCamRemote/Services`: app-level store/coordinator.
- `ActionCamRemote/UI`: SwiftUI app surfaces.
- `docs/compatibility.md`: protocol notes, status, and next proof gates.

## Safety

The DJI adapter sends experimental BLE commands for supported Action/Nano cameras. Test with non-critical footage first, keep camera firmware differences in mind, and expect command/status behavior to change across device models or firmware revisions.

## License

MIT. See `LICENSE`.
