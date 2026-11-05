# Camera metadata and artwork QA

Captured from the actual Multicam UI on the shared iPhone 18 Pro simulator,
using DEBUG fixtures and the repository's serial simulator reservation. No saved
camera data was erased. These are UI fixtures, not physical camera readings.

- [Separate volumes, light](x6-two-volumes-light.png) and [dark](x6-two-volumes-dark.png): battery, power, Internal Storage and SD Card; free-space-only text, no space before GB.
- [No SD card](x6-no-card.png): explicit Not inserted, internal storage retained.
- [Partial response](x6-partial-storage.png): only the reported volume is displayed.
- [New thumbnails, light](artwork-light-bottom.png) and [dark](artwork-dark-bottom.png): X2, ONE X, ONE R and ONE RS 1-Inch. SDK-only models show Unsupported in this simulator build because the device-only vendor SDK is absent.

Launch with `--demo-insta360-pairing --demo-insta360-x6
--demo-pairing-connected --demo-telemetry-info`, then tap the camera's chevron.
Add `--demo-no-sd` or `--demo-partial-storage` for the other states. Launch
`--demo-camera-artwork` for the thumbnail comparison. Fixtures are in memory and
do not write paired-camera preferences.

The four added image sets are copied from Trackside #360. ONE R uses scale 0.8;
ONE X uses scale 0.9. The ONE X PNG is the user's supplied high-resolution front
photo with its white background removed using the built-in image generator.
The source and exact edit prompt are retained in Trackside's
`docs/design-qa/camera-control-sdk/one-x-background-edit.md` and
`one-x-front-source.png` at commit `0ef786c44ab5ac397731af97e0f556ab23c4b5b2`.

## Watch handoff follow-up

The existing host has no watchOS simulator/runtime. The Release watchOS target
and SDK-enabled Release iPhone target were compiled, and the actual
`WatchCameraDetailView` was rendered in the shared iPhone simulator through a
DEBUG-only preview. These screenshots show that component at a 208-point width,
magnified 1.5×; they are not native watchOS screenshots or a WatchConnectivity
radio test.

- [X6, two volumes](watch/x6-two-volumes.png): both labeled free-space rows, SD Card ring using the SD capacity.
- [No optional metadata](watch/no-metadata.png): no stale readings or rings; connected camera/mode remain.

Launch `--demo-watch-metadata`, adding `--demo-watch-nano`, `--demo-watch-gopro`,
`--demo-watch-no-sd` or `--demo-watch-empty` for each state. The fixture uses the
production Watch camera decoder and detail view, without a live WCSession.
`sh ci_scripts/check_watch_camera_telemetry.sh` exercises the production phone
snapshot producer and Watch context consumer with only the system boundary and
camera store replaced. It covers all three brands, legacy GPS Remote, stable
snapshot equality, old/new compatibility and full/missing/partial/cleared volumes.
