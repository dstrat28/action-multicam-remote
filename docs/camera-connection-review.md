# Camera connection review

Reviewed PR #21 against the public remote references, official online SDK docs,
the approved local v1.11.3 SDK headers/Bluetooth sample, and the application's
connection/capture call chains. All reproductions below use host doubles or
pure session/policy tests. None establishes physical camera compatibility.

## Additional fixes

- GPS Remote: Bluetooth power-off during an outstanding service publication
  could strand pending adds after power-on. Rebuild the partial database and
  ignore obsolete add callbacks. Existing published sessions keep their normal
  restoration path. The regression simulates both interrupted services and
  late callbacks; actual iOS restart timing remains a hardware check.
- SDK: explicit Stop now supersedes pending mode or photo confirmation as well
  as Start. A matching but still-unconfirmed mode response reporting recording
  previously left Stop blocked. Late callbacks cannot consume the newer Stop.
  Video Start confirmation additionally requires a confirmed active video family.
  Capture errors clear stale status and report an unconfirmed outcome without
  resending capture commands.
- SDK: remove the socket-only heartbeat call. The online overview places a
  generic heartbeat example after Bluetooth setup, but the installed method
  header describes socket use and the Bluetooth sample polls capture status.
  Our common-run-loop timer continues deadlines and per-device status polling;
  its regression verifies polling during UI tracking and cleanup on disconnect.
  This does not prove that polling prevents every firmware disconnection.
- GoPro: busy-deferred Photo/Mode/Setting commands now retain the original
  command-result ID through the BLE response. Replacement/disconnection resolves
  the original queued result. Settings writes also carry results through ACK or
  error, rather than leaving the history at an optimistic queued-write result.
  Tests exercise the actual client with idle/busy status packets.
- Stop after reconnect: consume a pending explicit Stop once protocol readiness
  is reported, including GoPro and DJI Nano. Mere BLE connection is insufficient;
  repeated ready callbacks cannot replay it. GPS Remote shutter toggles remain
  excluded. Policy tests exercise the reconnect/ready/repeated-ready sequence.
- X5/X6 direct: emit Connected only after a valid capture-status response,
  rather than at notification setup. Bound missing capture status to 30 seconds
  even if ATT writes keep succeeding. The existing X5 pre-protocol fallback
  remains; capture commands are never automatically repeated or converted to
  GPS Remote toggles. Session tests simulate a permanently silent X6 and verify
  one failure/cleanup; transport tests verify no premature Connected event.
  A final regression reproduced a valid first X5 Unknown status being hidden
  by status deduplication. Protocol readiness now has a separate one-time event;
  `0A 00` and `0A 02 08 02` both establish Connected while keeping recording
  Unknown and Start blocked until a known stopped state arrives.

## SDK contract details checked

The official iOS list includes X3. Its normal video commands use the device's
`INSCameraBasicCommands` interface, not the global camera manager. The installed
capture-status header defines `state` using an unsigned integer enum and
documents `captureTime` in **seconds**, so the elapsed-seconds conversion is
correct. Its state values used by our mapping are:

| Value | SDK capture state |
| --- | --- |
| 0 | NotCapture |
| 1 | NormalCapture |
| 2 | TimelapseCapture |
| 7 | BulletTimeCapture |
| 9 | HDRVideoCapture |
| 12 | IntervalVideoCapture |
| 13 | TimeShiftCapture |
| 17 | SuperVideo |
| 18 | LoopRecording |
| 20 | FPV |
| 21 | MovieRecording |
| 22 | SlowMotion |
| 23 | Selfie |
| 24 | Pure |
| 29 | DashCam |
| 30 | PtzRecord |

Those active-state mappings are display/status interpretation, not hardware
validation of advanced modes. Start now preserves a confirmed camera-selected
video submode, shown as `Camera Video` for defined nonzero SDK video values (1–15).
Unknown or inactive mode reports cannot authorize or confirm video Start. Mode readback
follows the vendor example's Photo-first priority: `(0, 0)` is normal Photo and
cannot authorize or confirm video Start. Both fields must be returned successfully.
Photo and explicit Video/Photo selection remain normal-mode-only. The generic
`stopCapture` header describes video stopping but does not provide a complete
mode-by-model support matrix. Separate timelapse stop methods are documented
for ONE/ONE X, not as an X3 fallback. We do not guess a different X3 command.

The headers and online docs describe global CaptureStopped/TemperatureStatus
notifications without a reliable documented per-camera identity contract.
Temperature notification comments specifically mention GO, not a guarantee for
X3. Applying those events to all connected cameras would be unsafe. The adapter
continues per-device status polling; attributed abnormal-stop/temperature
alerts remain unimplemented pending vendor identity guidance or a real trace.
An overheating or card-full stop can therefore appear through status without
the vendor-specific reason/alert. Do not claim that feature is covered.

The vendor repository has an unresolved report of delayed X3 Stop completion on
long clips and ambiguous timeout outcomes. We retain bounded confirmation,
unknown status on uncertainty, and no automatic SDK capture retry. Real X3
long-clip Stop/finalization and reconnect behavior are required checks before
describing this integration as reliable for a motorcycle ride.

## Sources and scope

- [SDK model/setup guide](https://github.com/Insta360Develop/Insta360-Developer_Docs/blob/main/docs/en/sdk/x-ace-go/ios/guide.md).
- [SDK Bluetooth, capture, mode and notification API](https://github.com/Insta360Develop/Insta360-Developer_Docs/blob/main/docs/en/sdk/x-ace-go/ios/api.md).
- [Heartbeat documentation issue](https://github.com/Insta360Develop/iOS-SDK/issues/80), used as a lead and checked against the approved installed package.
- [X3 long-recording Stop report](https://github.com/Insta360Develop/iOS-SDK/issues/85), a user report rather than a vendor guarantee.
- [Open GoPro BLE control](https://gopro.github.io/OpenGoPro/ble/features/control.html).
- X3/RS ESP32 and Pico references, Apple ATT contract, and the physical check
  plan are linked in [X3 pairing investigation](insta360-x3-pairing.md).

No proprietary headers, binaries, sample implementation, or customer serials
are copied into this repository. No merge, release, signed install, physical
X3 test, Sena test, or actual Siri invocation is represented by these checks.
