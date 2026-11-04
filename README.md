# Multicam

Control multiple GoPro, DJI, and Insta360 action cameras over Bluetooth from your iPhone or iPad, with Apple Watch and CarPlay recording controls.

[Download Multicam on the App Store](https://apps.apple.com/us/app/action-multicam-remote/id6784017391).

## Features

- Start and stop selected cameras together or control each one individually.
- Take photos, switch capture modes, and select saved GoPro presets.
- View recording, battery, and storage status where supported.
- Control recording from Apple Watch, CarPlay, or a Live Activity on the Lock Screen and Dynamic Island.
- Add highlight markers to GoPro and DJI Action 4/5/6 recordings.
- Send optional iPhone GPS telemetry to compatible DJI cameras.
- Manage cameras and nicknames, enable larger controls, and send feedback with diagnostics from Settings.

## Camera Support

| Brand | Cameras |
| --- | --- |
| GoPro | HERO9–13 Black, HERO11 Black Mini, MAX 2, LIT HERO |
| DJI | Osmo Action 4, Action 5 Pro, Action 6, Osmo 360, Osmo Nano |
| Insta360 — experimental | Ace, Ace Pro, Ace Pro 2, X3, X4, X4 Air, X5, X6, ONE RS, GO 3, GO 3S, GO Ultra |
| Insta360 SDK — experimental, opt-in | X6, X5, X4 Air, X4, X3, X2, ONE X, ONE R, ONE RS, ONE RS 1-Inch |

See the [full compatibility matrix and hardware-testing status](docs/camera-support.md). DJI Osmo Pocket 3 is currently unsupported.

## Limitations

- Insta360 support is experimental. X5/X6 use direct Bluetooth for normal video; X6 also reports battery/storage. X5 can fall back to GPS Remote during setup. Other Insta360 models supported by standard builds pair through the camera's **Insta360 GPS Remote** menu. Verify the camera mode before group recording; recording status may remain unknown.
- Wake is supported for paired GoPros and Osmo Nano. Insta360 wake remains unverified; other DJI models cannot be woken by this app.
- Phone GPS writes location into recordings and requires permission and the iPhone app to remain open and connected.
- Apple Watch controls require the paired iPhone.
- Live preview and media browsing are unavailable.

See [camera-specific limitations and pairing notes](docs/camera-support.md), [X5/X6 direct-control notes](docs/insta360-direct-control.md), and [connection reliability notes](docs/camera-control-reliability.md) for details.

## Development

Open `ActionCamRemote.xcodeproj` and select the `ActionCamRemote` scheme. Follow [CONTRIBUTING.md](CONTRIBUTING.md) for requirements, simulator builds, signing with your own Apple team, and reporting camera issues. Camera testing requires a physical iPhone or iPad.

CarPlay development and testing notes are in [docs/carplay.md](docs/carplay.md).

An opt-in [Insta360 SDK Bluetooth prototype](docs/insta360-sdk-prototype.md) is
available for approved SDK device builds. It remains off by default and requires
physical camera validation.

## Acknowledgements

Thank you to the projects whose documentation, implementations, and camera captures informed Multicam:

**GoPro**

- [OpenGoPro](https://github.com/gopro/OpenGoPro) — official BLE specification and examples.
- [GoEasyPro](https://github.com/sepp89117/GoEasyPro_Android) — response sequencing research.

**DJI**

- [Osmo GPS Controller Demo](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo) — official R SDK control, status, and GPS reference.
- [osmosis](https://github.com/KonradIT/osmosis) — Osmo Nano DUML research.
- [DJI-Remote](https://github.com/rhoenschrat/DJI-Remote) — highlight-tag research.
- [Osmo Action Remote](https://github.com/retweakeverything/osmo-action-remote) — pairing and command lifecycle.

**Insta360**

- [X6 Watch Remote](https://github.com/AndreySemjonov/X6-Watch-Remote) — X6 framing, status, telemetry, and captured fixtures.
- [luna-ai-cut](https://github.com/diamondfsd/luna-ai-cut) — UCD2 framing and checksum implementation used by X6 Watch Remote.
- [Insta360 X5 toolkit](https://github.com/soul667/insta360-x5-toolkit) — X5 framing, sync, heartbeat, and capture examples.
- [insta360-m5stick-remote](https://github.com/marcelpallares/insta360-m5stick-remote) — GPS Remote commands, recording status, and multicamera behavior.
- [insta360_ble_esp32](https://github.com/pchwalek/insta360_ble_esp32) — GPS Remote service and commands.
- [Insta360 BLE GPS spec](https://github.com/TheAngryRaven/insta360-ble-gps-spec) — X4 packet and button-sequence observations.
- [DovesDataLogger](https://github.com/TheAngryRaven/DovesDataLogger/blob/0077141ea3a43de68e1d9dc2e761e6674d9e31b3/tests/insta360_protocol_test.cpp) — X4 display-timer packet used in regression checks.

GoEasyPro and DovesDataLogger are GPL-3.0 research references; their application source code is not incorporated into Multicam. License notices for the MIT implementations and examples are retained in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), which is bundled in the iPhone app.

Multicam is an independent project and is not affiliated with, endorsed by, or sponsored by GoPro, DJI, Insta360, or their affiliates.

## License

Multicam's original source code is [MIT-licensed](LICENSE). Third-party notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). See [PRIVACY.md](PRIVACY.md) for local storage and diagnostic sharing.
