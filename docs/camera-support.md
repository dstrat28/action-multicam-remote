# Camera support and limitations

Support and hardware-testing status are listed separately. Camera behavior may vary by firmware; a tested camera does not establish that every feature has been verified on that model.

## Compatibility

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
| Insta360 X6 | No | No |
| DJI Osmo Pocket 3 | No | Yes |
| GoPro HERO | No | No |
| GoPro MAX | No | No |
| GoPro HERO8 Black | No | No |
| DJI Osmo Action 3 | No | No |
| DJI Action 2 | No | No |
| DJI Osmo Action (original) | No | No |

## Limitations

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

## Protocol and feature notes

GoPro support uses the public Open GoPro BLE API. DJI support uses DJI's R SDK protocol and BLE/DUML behavior. Experimental Insta360 support emulates the Bluetooth GPS Remote protocol and does not use Wi-Fi.

GoPro factory and custom presets are discovered over Bluetooth with camera-provided names and IDs. The menu follows camera-side changes. Cameras that do not provide a preset list retain the basic mode picker. Preset selection requires hardware verification on each model.

Paired GoPros can wake for up to eight hours after sleep. Osmo Nano also supports Bluetooth wake. The Insta360 remote protocol provides a mode-cycle command; valid camera timer packets indicate recording, while missing or stale timers leave status unknown.
