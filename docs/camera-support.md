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
| Insta360 X2 | Experimental (SDK only) | No |
| Insta360 ONE X | Experimental (SDK only) | No |
| Insta360 ONE R | Experimental (SDK only) | No |
| Insta360 ONE RS 1-Inch | Experimental (SDK only) | No |
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

## Limitations

- Approved SDK device builds can opt into Bluetooth control for the full official iOS SDK camera list. X2, ONE X, ONE R, and ONE RS 1-Inch require that backend; they have no GPS Remote fallback. The SDK switch appears only in SDK device builds and takes effect after restarting Multicam. All SDK camera control remains hardware-unverified. See [SDK setup and validation](insta360-sdk-prototype.md).
- Camera behavior can vary by model and firmware; see the hardware-testing status above.
- X5/X6 direct Bluetooth control uses community hardware captures (X5: October 2026 firmware; X6: 1.1.7); Multicam has not been tested on Insta360 hardware. Set normal Video mode on the camera. Direct mode changes, photos, settings, and wake are unavailable. X5 can fall back to GPS Remote before protocol confirmation or any capture transmission. [Protocol and validation details](insta360-direct-control.md).
- Insta360 GPS Remote support requires selecting `Insta360 GPS Remote` in the camera's Bluetooth Remote settings while Multicam remains open.
- Insta360 GPS Remote wake is experimental and has not been verified on hardware. Multicam attempts a targeted iBeacon advertisement while the app is in the foreground. iOS supports this fixed beacon format, but the ESP32 remote reference includes an extra byte that this format does not reproduce; successful wake must not be assumed.
- Insta360 GPS Remote recording and photo commands use the same shutter toggle in the camera's current mode. Recording state is inferred from timer packets, and an unknown state does not establish that the camera is stopped or in Video mode. Verify the camera's mode before using group recording. Bluetooth queues retain only the latest unsent command per camera for up to two seconds and discard it if the connection or observed recording state changes. Discarded commands are reported in Diagnostics and are not automatically retried.
- Pair multiple Insta360 GPS Remote cameras one at a time. iOS does not expose an incoming camera's Bluetooth address, so Multicam assigns new GPS Remote subscriptions in the order connection requests were made.
- Insta360 GPS Remote control does not expose camera settings, battery/storage telemetry, highlight markers, preview, or media transfer. Mode changes are not acknowledged by the remote protocol and must be verified on the camera.
- Wake is not supported on other DJI cameras because their `WKP` manufacturer-data wake advertisement cannot be reproduced through iOS's fixed iBeacon format or ordinary Core Bluetooth advertising.
- Highlights are recording-only. DJI cameras do not acknowledge highlight commands, so verify markers before relying on them for critical footage.
- Phone GPS requires location permission and the iPhone app to remain open and connected. Enabling it writes precise location telemetry to recordings; the complete path has been tested on Action 6.
- Apple Watch commands pass through the paired iPhone; the Watch does not connect directly to cameras.
- Live preview and media browsing are not supported because they require Wi-Fi rather than the app's Bluetooth-first control path.
- Physical cameras cannot connect to iOS Simulator.

## Protocol and feature notes

GoPro support uses the public Open GoPro BLE API. DJI support uses DJI's R SDK protocol and BLE/DUML behavior. Standard builds use direct Bluetooth control for Insta360 X5/X6, with GPS Remote fallback for X5; their other supported Insta360 models use GPS Remote emulation. Neither standard path uses Wi-Fi or the Insta360 SDK. The optional SDK backend supports the full official iOS camera list described above.

GoPro factory and custom presets are discovered over Bluetooth with camera-provided names and IDs. The menu follows camera-side changes. Cameras that do not provide a preset list retain the basic mode picker. Preset selection requires hardware verification on each model.

Paired GoPros can wake for up to eight hours after sleep. Osmo Nano also supports Bluetooth wake. The Insta360 remote protocol provides a mode-cycle command; valid camera timer packets indicate recording, while missing or stale timers leave status unknown.
