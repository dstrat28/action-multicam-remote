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
| Insta360 — experimental | Ace, Ace Pro, Ace Pro 2, X3, X4, X4 Air, X5, ONE RS, GO 3, GO 3S, GO Ultra |

See the [full compatibility matrix and hardware-testing status](docs/camera-support.md). Insta360 X6 and DJI Osmo Pocket 3 are currently unsupported.

## Limitations

- Insta360 support is experimental. Pair through the camera's **Insta360 GPS Remote** menu, keep it awake, and verify its mode before group recording. Recording status may remain unknown; battery and storage telemetry are unavailable.
- Wake is supported for paired GoPros and Osmo Nano. Insta360 wake remains unverified; other DJI models cannot be woken by this app.
- Phone GPS writes location into recordings and requires permission and the iPhone app to remain open and connected.
- Apple Watch controls require the paired iPhone.
- Live preview and media browsing are unavailable.

See [camera-specific limitations and pairing notes](docs/camera-support.md) for details.

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

Multicam is an independent project and is not affiliated with, endorsed by, or sponsored by GoPro, DJI, Insta360, or their affiliates.

## License

MIT. See [LICENSE](LICENSE).
