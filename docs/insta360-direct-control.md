# Insta360 X5/X6 direct Bluetooth

X5 and X6 are enabled directly, with no Settings toggle or SDK dependency. Pair an awake
X5/X6 from Multicam's camera list. Enable Bluetooth and set normal Video mode on the
camera before recording. The direct path connects to the camera rather than Multicam's advertised `Insta360 GPS Remote` service. X5 retains a GPS Remote fallback for firmware that does not establish the documented direct protocol.

The phone is the BLE central; each camera has its own client/session. BE80 is the
control service, BE81 accepts writes with response, and BE82 sends notifications.
X6 UCD2 frames contain a correlated message ID, protobuf body, and camera-specific
CRC. X6 writes use ATT write-with-response. X5 uses write-without-response when available, with 20-byte chunks and CoreBluetooth backpressure. Writes respect the negotiated ATT size; notification framing supports
arbitrary chunk boundaries. Invalid frames terminate the session rather than
reusing an ambiguous stream.

Implemented commands:

| Code | Purpose |
| --- | --- |
| 4 | Explicit normal-video Start |
| 5 | Explicit Stop |
| 15 | Recording status and elapsed time |
| 8 | X6-only battery and active storage options (11, 20, 176) |

An ATT acknowledgement does not confirm camera acceptance. A successful camera
reply does not confirm recording state. Capture commands are sent once and
verified using subsequent status reads. Start requires a recent confirmed
stopped state. Stop can replace an unsent Start; a transmitted Start is never
automatically repeated. Unknown or stale state remains unknown.

X5 uses a separate length-prefixed network frame, a `syNceNdinS` sync message at setup, and a two-second heartbeat. The X6 UCD2 envelope is never sent to X5. Optional X5 sync echoes do not acknowledge capture commands.

Status is polled once per second when the previous request has finished.
Battery/storage are refreshed every 30 seconds and expire after 75 seconds;
battery events do not refresh storage. Replies are matched to their request ID.
Missing transport completion closes the link, so a late callback cannot acknowledge a
different frame. Reconnection clears pending capture intents.

X5 falls back to GPS Remote if service discovery, initial frame parsing, or the initial status exchange fails before any protocol confirmation or capture transmission. The central connection is closed before the GPS service is started. Capture intents are cleared during the switch; they are never converted into shutter toggles. A successful GPS route is remembered per camera. Direct setup is tried again after forgetting and re-pairing that camera.

## Evidence and limits

X5 framing follows [soul667/insta360-x5-toolkit](https://github.com/soul667/insta360-x5-toolkit), commit `eb6c4ee6e6c8f9189d1d1c85efa645538f760b2a`. That project reports two X5 cameras on October 2026 firmware, and publishes complete START/ACK, sync, and heartbeat examples. Those examples are checked byte-for-byte. Remaining edge cases are synthetic. Its STOP filename illustration has inconsistent byte counts, so that illustration is not used as a golden fixture.

The implementation adapts [X6 Watch Remote](https://github.com/AndreySemjonov/X6-Watch-Remote)
at commit `4ea62293d706210236cef63fb0ce488549b7bbcb`, including its
[protocol observations](https://github.com/AndreySemjonov/X6-Watch-Remote/blob/4ea62293d706210236cef63fb0ce488549b7bbcb/docs/PROTOCOL.md).
That project reports X6 firmware **1.1.7, normal video mode** hardware testing.
Its captured responses and expected request bytes are replayed by our host regression check.
Additional malformed-input, timeout, and command-ordering cases are synthetic.

Multicam's integration has not been validated on physical Insta360 cameras. Community hardware observations and offline regressions establish the current implementation scope. Mode changes, photos, settings, wake, preview, media transfer,
encrypted headers, and logical multi-fragment messages are not implemented.
Capture status does not establish Video mode, so CarPlay Start remains unavailable
until mode can be reported; confirmed recording can be stopped through CarPlay.
The reference reports Bluetooth reply gaps lasting **12+ seconds after Stop**.
Multicam waits up to 25 seconds for Stop confirmation and repeats only status reads.

Credits and upstream MIT notices are in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md),
which is also bundled in the iPhone app.
