# X3 pairing investigation and verification

An X3 report on 1.2.1 (97) reaches Multicam's GPS Remote service, writes its
serial and settings/status frames to CE81, and never produces a CE82
subscription callback. That is a partial remote connection, not a working
command channel. The log alone cannot identify why the camera disconnects;
identical packet logging is throttled and does not establish retry timing.

## Legacy Bluetooth changes

- Validate every request in a CoreBluetooth write callback before assigning
  cameras or applying status. Reject the whole batch on an unsupported endpoint,
  missing value, or nonzero offset; respond once to the first request. Successful
  batches still process every CE81 frame. This is the ATT acknowledgement the
  remote protocol uses, not an application-level authentication reply.
- When an X3 is requested, publish the nine-characteristic D0FF companion service
  exposed by the original X3/RS reference. Its read values and passive write
  endpoints match that reference. Companion writes never initiate recording or
  firmware changes. Other models initially retain their existing CE80 profile;
  adding an X3 preserves CE80 and existing subscribers. The companion stays
  published for the manager's lifetime once added.
- Advertise only after all services required by the requested cameras have been
  added successfully. Repeated requests do not duplicate pending service adds;
  failures can be retried. Restoration reuses complete profiles and adds a
  missing X3 companion without replacing CE80.

The X3/RS reference declares CE82 **Notify**, explicitly initializes its CCCD,
and supplies an initial one-byte value. CoreBluetooth manages subscription
descriptors; Multicam keeps a dynamic notify-only characteristic and waits for
the actual subscription callback. It does not fake a subscription, add an
encryption requirement, or send an undocumented CE82 handshake. The companion
service closes a concrete difference from an X3-tested implementation, but the
report contains no companion access trace: it remains a compatibility fix to
test, not a proven diagnosis. CE80 remains the advertised UUID, as in the Pico
reference, to preserve discovery/name space; the companion is discoverable over
GATT. GPS liveness details captured on X4 are not assumed to apply to X3.

## SDK route and Siri

The vendor lists X3 in its supported iOS models and documents Bluetooth camera
control. Our SDK adapter connects to the camera UUID through its own vendor
Bluetooth manager, obtains that device's command interface, queries capture
status/mode, and calls explicit `startCapture` / `stopCapture`. It does not use
Multicam's CE80 service or wait for a CE82 subscription.

Siri reaches `CameraStore.startAllRecording()` / `stopAllRecording()`. Two
app-side fixes accompany this investigation: Stop All includes connected,
paired SDK cameras whose capture status is unknown; GPS Remote toggles retain
their confirmed-recording gate. Start after a mode change waits for SDK mode
confirmation rather than abandoning it at the normal 1.6-second delay. It
does not repeat mode/capture calls and has a bounded wait. Vendor acceptance
alone still cannot confirm recording.

Host regressions exercise the actual remote delegate with CoreBluetooth doubles,
mixed valid/invalid batches, companion reads/writes, publication/restoration,
CE82 readiness, and unicast/backpressure. SDK adapter tests include synthetic
X3 start/stop, expired capture status, and delayed Photo-to-Video confirmation.
Model tests cover the Stop All target policy and bounded mode preparation.
These tests do not execute Siri, Sena firmware, real Bluetooth, or X3 firmware.
Native unsigned app builds additionally check real Apple/vendor APIs and linking.

## Physical X3 check still required

1. Record the X3 firmware version. Keep the awake camera close and Multicam in
   the foreground. Delete a stale remote entry on the camera and pair afresh
   with SDK disabled. Verify a CE82 subscription and camera-connected event,
   not just CE81 writes. Check manual start/stop twice in normal Video mode.
2. Enable SDK, disconnect/reconnect, and confirm Diagnostics selects SDK
   Bluetooth. This uses the app connection path rather than selecting the
   emulated GPS Remote on the camera. Complete any camera authorization prompt.
   Verify manual start/stop and Photo-to-Video Start All.
3. With the Sena connected to the iPhone, verify Siri Start All / Stop All,
   including foreground/background transitions and reconnect. Observe the
   camera's actual recording indicator and collect diagnostics for failures.

Neither route is marked hardware-tested by this change. No release or customer
communication is part of the patch.

## Sources

- [Apple: didReceiveWrite transaction contract](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanagerdelegate/peripheralmanager(_:didreceivewrite:)).
- [Original X3/RS ESP32 implementation](https://github.com/pchwalek/insta360_ble_esp32/blob/8664c17f34e3b843ed1e144d349f11b2819266f6/Insta_BLE.ino).
- [Pico W X4 remote](https://github.com/tsunghowu/insta360_ble_rc_rpi_pico_w/blob/main/ble_ski_cam_remote.py), which also exposes the companion but is not independent X3 hardware evidence.
- [X4-captured GPS Remote protocol](https://github.com/TheAngryRaven/insta360-ble-gps-spec), useful for architecture but not proof of X3-specific behavior.
- [Official iOS SDK model list](https://github.com/Insta360Develop/Insta360-Developer_Docs/blob/main/docs/en/sdk/x-ace-go/ios/guide.md) and [Bluetooth/capture API guide](https://github.com/Insta360Develop/Insta360-Developer_Docs/blob/main/docs/en/sdk/x-ace-go/ios/api.md).
- [Official X3 remote pairing instructions](https://onlinemanual.insta360.com/x3/en-us/camera/connect/gpsremote) and [remote troubleshooting](https://onlinemanual.insta360.com/gpsactionremote/en-us/troubleshooting/connect-problem).
