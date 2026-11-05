# CarPlay development

The published app enables CarPlay by default. Contributors can build the iPhone app with their own Apple development team and bundle identifiers by setting `MULTICAM_CARPLAY_ENABLED=NO`. They do not need access to the publisher's team. To use CarPlay on a physical device under another team, request the Driving Task entitlement for that team's App ID and use matching provisioning profiles. Unsigned iOS Simulator builds do not require CarPlay provisioning profiles.

See [Apple's entitlement setup](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements) for the approval and provisioning process. Run the commands below from the repository root.

The single CarPlay screen uses Apple's native `CPListTemplate` for previously paired cameras. Selection appears only in each camera's checkmark; the detail shows Connected, Not Connected, Connecting, Recording, or Unsupported. Connected cameras also show reported battery percentage (or bars) and external power, when available; disconnected cameras do not show cached battery readings. When selected cameras cannot record, a standard section header explains why. No selection prompt appears when nothing is selected. A native rounded button in the navigation bar stays visible while scrolling the list. It shows Record when the selected cameras are idle, disabled Starting... while any selected connected camera is starting, and Stop once recording is confirmed, including a mixed idle/recording selection.

It shares the iPhone's camera store, including on a CarPlay-first launch. Cameras are automatically selected when they connect through the same store behavior as the iPhone; drivers can still deselect them. Camera selection changes are shared with the iPhone. Start requires every selected camera to be connected, in confirmed Video mode, and confirmed ready/stopped; it does not take photos, change modes, or partially start a group. Stop affects selected cameras that are recording or starting, including the existing reconnect-and-stop path. Pairing and detailed settings remain on iPhone before the drive.

CarPlay observes discrete connection, selection, recording, and recording-readiness changes in the shared store and updates immediately, including changes initiated from iPhone. Continuous power telemetry refreshes every 10 seconds while the CarPlay scene is active; battery, external power, elapsed time, RSSI, and list reordering alone do not trigger event redraws. Updates after a discrete event can also include the latest power reading. The phone and CarPlay receive the same Bluetooth data; there is no additional timer delay for connection changes. Treating discrete state transitions separately from periodic telemetry is an interpretation of Apple's Driving Task guideline, which explicitly limits periodic refreshes and does not expressly document an event-update exception.

Insta360 remote mode/status reporting can remain unknown. Such cameras cannot start recording through CarPlay until Video mode and stopped/ready state are known. A confirmed recording can still be stopped. Hardware validation is required for each supported brand.

Signing and testing:

1. Ensure development and distribution provisioning profiles include the approved **CarPlay Driving Task App** capability for this App ID.
2. Build normally: `MULTICAM_CARPLAY_ENABLED` defaults to `YES` and selects `ActionCamRemote/CarPlay/MulticamCarPlay.entitlements` for the iPhone target. Pass `MULTICAM_CARPLAY_ENABLED=NO` only for builds that should omit CarPlay.
3. Use Apple's CarPlay Simulator with a physical iPhone to validate Bluetooth camera control. Xcode's iOS Simulator can validate templates with `--demo-connected-cameras`, but cannot connect to real cameras. Reuse the existing local simulator pool and hold the shared per-device simulator lock for the entire install/UI session.
4. Verify CarPlay-first launch with iPhone locked, concurrent phone/CarPlay selection, selected-only Start/Stop, disabled Starting... followed by enabled Stop after confirmation, camera disconnect/reconnect during recording, empty/unsupported/photo/unknown-status states, CarPlay disconnect/reconnect, and each supported camera brand on a real head unit. Check that selecting/deselecting cameras never sends a shutter command and that Stop does not affect deselected cameras.

The host regression check runs without a CarPlay entitlement or simulator:

```sh
xcrun swiftc -parse-as-library \
  ActionCamRemote/Models/CameraStorageVolume.swift \
  ActionCamRemote/Models/CameraModels.swift \
  ActionCamRemote/Bluetooth/Insta360RemoteProtocol.swift \
  ActionCamRemote/CarPlay/CarPlayCameraState.swift \
  Tests/CarPlayCameraStateRegression.swift \
  -o /tmp/multicam-carplay-regression
/tmp/multicam-carplay-regression
```

The controller observation check is also run in CI:

```sh
sh ci_scripts/check_carplay_controller.sh
```

It compiles the actual CarPlay controller against minimal host-side template and store doubles. It checks immediate connection/recording updates, the periodic battery refresh, and pause/resume/disconnect lifecycle behavior without a simulator or entitlement. Native template rendering, Bluetooth behavior, and signed provisioning still require separate app/device checks.
