# Camera Compatibility Notes

Updated: 2026-07-23

## Architecture

Bluetooth is the primary transport because Multicam needs to control multiple cameras at the same time. Wi-Fi can be added later for single-camera live preview, media browsing, or operations that require the camera access point, but the current app avoids a design that assumes the phone can join several camera Wi-Fi networks at once.

Brand-specific protocol details live behind `BLECameraDeviceClient` implementations:

- `GoProBLEClient` uses Open GoPro BLE commands, settings, and query/status packets.
- `DJIExperimentalBLEClient` uses experimental DUML-style packets over DJI BLE services for supported Action/Nano cameras.

The app uses an allowlist for camera control. GoPro models listed by the public Open GoPro BLE API are enabled through the shared GoPro client, with HERO13 Black tested directly. DJI models are enabled individually with model-scoped behavior and remain clearly marked untested until verified because DJI does not publish an equivalent Action/Nano BLE control API.

## GoPro HERO13 Black

Status: tested.

Implemented:

- discovery using advertised service `0xFEA6`;
- command/control, settings, query, and response characteristics;
- keepalive;
- shutter on/off;
- status registration/query;
- recording-state reads;
- hardware model detection;
- Video preset/group switching;
- explicit wake/connect/start flow from Available state.

Important behavior:

- The app avoids passive auto-connect for remembered GoPros because a BLE connection can wake or keep the camera awake.
- A GoPro can still be selected and started from Available state; that path is an explicit user command.

## Other Open GoPro BLE Cameras

Status: compatible, untested.

The public Open GoPro BLE API lists these additional compatible cameras:

- GoPro LIT HERO;
- GoPro MAX 2;
- GoPro HERO12 Black;
- GoPro HERO11 Black Mini;
- GoPro HERO11 Black;
- GoPro HERO10 Black;
- GoPro HERO9 Black.

Implemented:

- model detection from documented advertisement model IDs and common model-code/name strings;
- the same Open GoPro BLE pair/connect, shutter, status, setting, and query client used by HERO13 Black.

Known limits:

- These models have not been verified locally with hardware.
- Wake-from-off, pairing UX, mode switching, and setting/status labels may vary by firmware or model.
- MAX/MAX 2 behavior may require additional camera-specific mode handling because 360 camera settings differ from HERO cameras.

## DJI Osmo Action 4

Status: experimental, untested.

Evidence:

- [DJI documents](https://repair.dji.com/help/content?customId=01700008289&lang=en&paperDocType=ARTICLE&re=US&spaceId=17) that its GPS Bluetooth Remote Controller connects to Action 4, Action 5 Pro, and Action 6 over Bluetooth.
- The same official documentation describes multi-camera control of up to 16 cameras for those three Action models and explicitly excludes Osmo 360 from multi-control.
- That makes Action 4 a strong candidate for the app's shared Bluetooth control path, but it does not prove that DJI's remote protocol and the app's R SDK packets are identical.

Implemented:

- name-based model detection for Action 4, Osmo Action 4, and OA4 advertisements;
- pairing and BLE connection through the shared DJI R SDK handshake path;
- conservative recording-state behavior matching the unverified Action 5 profile;
- existing front-view Action-series product thumbnail.

Known limits:

- Connection, record start/stop, and recording-state interpretation require direct Action 4 hardware verification.
- Put the camera in Video mode on-device before testing recording.
- Wake, mode switching, and settings control are not claimed.

## DJI Osmo Action 5 Pro

Status: experimental, untested.

Implemented:

- name-based model detection for Action 5, Action 5 Pro, and OA5 advertisements;
- pairing and BLE connection through the shared DJI R SDK handshake path;
- conservative recording-state behavior that does not inherit Action 6-specific assumptions.

Known limits:

- Connection and record control require direct hardware verification.
- Legacy DUML routing and fallback commands are not claimed as model-specific Action 5 support.
- Put the camera in Video mode on-device before testing recording.
- Settings control is not mapped.

## DJI Osmo Action 6

Status: tested, experimental.

Implemented:

- BLE discovery and private writable characteristic selection;
- DUML route selection for Action 6;
- record start/stop while the camera is awake and in Video mode;
- Action 6 recording-state reads from the short `0x70` system-state response;
- protection against stale compact status packets that report stopped while the camera is actually recording.

Known limits:

- Sleep wake has not been observed to work over BLE. DJI Mimo also did not find the Action 6 while it was off in local testing, so this may be a camera/firmware limitation rather than an app bug.
- Mode switching is not reliable enough to expose as supported. Put the camera in Video mode on-device before recording.
- Settings control is not mapped.

## DJI Osmo Nano

Status: tested, experimental.

Implemented:

- BLE connect while the camera is awake;
- record start/stop;
- recording-state reads from DJI camera-state notifications;
- Nano-specific state smoothing for connected record/start transitions.

Known limits:

- Sleep wake may be possible over BLE, but local testing was buggy: the camera could start recording from sleep inconsistently, then the app would see unstable connect/disconnect state and sometimes could not stop the recording. The app no longer exposes DJI Available-state recording and treats sleeping DJI cameras as Not Connected.
- Mode switching is not reliable enough to expose as supported. Put the camera in Video mode on-device before recording.
- Settings control is not mapped.
- Off/asleep advertisement behavior may vary by firmware and power state.

## DJI Osmo Pocket 3

Status: not supported.

Pocket 3 is recognized by name/model so it can be shown clearly in the app, but pairing, selection, and record controls are disabled.

What local testing found:

- Pocket 3 advertises BLE and can send status-like traffic.
- Physical record-button presses produced incoming notifications, but replaying those packets and sending the known DJI Action/Nano record command families did not start or stop recording.
- DJI's public Pocket 3 docs describe phone control through Bluetooth plus Wi-Fi, and LightCut/Mimo-style flows appear to use Bluetooth for discovery/handshake before joining the camera Wi-Fi network.

Current decision:

- Do not claim Pocket 3 BLE-only recording support.
- Do not include Pocket 3 in multicam selection or automatic reconnect.
- Revisit only if a reproducible BLE command path or official API becomes available.

## Other Cameras

Status: not supported.

Any camera outside the documented Open GoPro BLE list, DJI Osmo Action 4, DJI Osmo Action 5 Pro, DJI Osmo Action 6, and DJI Osmo Nano is shown as Unsupported. Recent unsupported models are still recognized visually: GoPro HERO, MAX, and HERO8 Black, plus DJI Osmo 360, Osmo Action 3, DJI Action 2, and the original Osmo Action. They receive front-view product thumbnails but stay disabled until their BLE behavior is tested or documented clearly enough to map explicitly. Cameras without a product asset use a neutral camera icon.

## Next Proof Gates

1. Capture DJI mode-switch traffic from first-party apps/accessories if reliable Video-mode switching becomes important.
2. Expand GoPro settings support after querying and rendering device-specific capabilities.
3. Decide whether Wi-Fi preview/media workflows belong in this app or a companion tool.
4. Revisit Pocket 3 only if a BLE-only control route is found or the app grows a deliberate single-camera Wi-Fi control mode.
