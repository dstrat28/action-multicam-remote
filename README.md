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

See the [full compatibility matrix and hardware-testing status](docs/camera-support.md). DJI Osmo Pocket 3 is currently unsupported.

## Limitations

- Insta360 support is experimental. X5/X6 use direct Bluetooth for normal video; X6 also reports battery/storage. X5 can fall back to GPS Remote during setup. Other models pair through the camera's **Insta360 GPS Remote** menu. Verify the camera mode before group recording; recording status may remain unknown.
- Wake is supported for paired GoPros and Osmo Nano. Insta360 wake remains unverified; other DJI models cannot be woken by this app.
- Phone GPS writes location into recordings and requires permission and the iPhone app to remain open and connected.
- Apple Watch controls require the paired iPhone.
- Live preview and media browsing are unavailable.

See [camera-specific limitations and pairing notes](docs/camera-support.md), [X5/X6 direct-control notes](docs/insta360-direct-control.md), and [connection reliability notes](docs/camera-control-reliability.md) for details.

## Development

Open `ActionCamRemote.xcodeproj` and select the `ActionCamRemote` scheme. Follow [CONTRIBUTING.md](CONTRIBUTING.md) for requirements, simulator builds, signing with your own Apple team, and reporting camera issues. Camera testing requires a physical iPhone or iPad.

CarPlay development and testing notes are in [docs/carplay.md](docs/carplay.md).

## Acknowledgements

Thank you to these projects for helping make Multicam possible:

- [dji-sdk/Osmo-GPS-Controller-Demo](https://github.com/dji-sdk/Osmo-GPS-Controller-Demo) for DJI's R SDK BLE, camera-control, status, and GPS reference implementation.
- [gopro/OpenGoPro](https://github.com/gopro/OpenGoPro) for GoPro's official BLE interface specification, documentation, and demos.
- [KonradIT/osmosis](https://github.com/KonradIT/osmosis) for DJI Osmo Nano DUML research and documentation.
- [rhoenschrat/DJI-Remote](https://github.com/rhoenschrat/DJI-Remote) for DJI highlight-tag research.
- [marcelpallares/insta360-m5stick-remote](https://github.com/marcelpallares/insta360-m5stick-remote) for the MIT-licensed Insta360 GPS Remote, Ace Pro 2/X5, multicamera, command, and recording-status reference implementation.
- [pchwalek/insta360_ble_esp32](https://github.com/pchwalek/insta360_ble_esp32) for the MIT-licensed CE80/CE81/CE82 GPS Remote service and command reference implementation.
- [AndreySemjonov/X6-Watch-Remote](https://github.com/AndreySemjonov/X6-Watch-Remote) for the MIT-licensed X6 direct Bluetooth protocol, Swift framing/status/telemetry implementation, and captured regression fixtures.
- [diamondfsd/luna-ai-cut](https://github.com/diamondfsd/luna-ai-cut) for the MIT-licensed UCD2 framing and checksum implementation used by X6 Watch Remote.
- [soul667/insta360-x5-toolkit](https://github.com/soul667/insta360-x5-toolkit) for documented, hardware-verified X5 direct Bluetooth framing, sync/heartbeat behavior, and capture examples.
- [TheAngryRaven/insta360-ble-gps-spec](https://github.com/TheAngryRaven/insta360-ble-gps-spec) for X4 GPS Remote packet observations, including connection-local button sequence numbers (protocol research reference).
- [retweakeverything/osmo-action-remote](https://github.com/retweakeverything/osmo-action-remote) for DJI pairing and command-lifecycle reference behavior.
- [sepp89117/GoEasyPro_Android](https://github.com/sepp89117/GoEasyPro_Android) for GoPro response sequencing research (GPL-3.0 reference; no source code incorporated).

Adapted code and fixtures retain their upstream licenses in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Multicam is an independent project and is not affiliated with, endorsed by, or sponsored by GoPro, DJI, Insta360, or their affiliates.

## License

MIT. See [LICENSE](LICENSE).
