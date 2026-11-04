# Camera connection and command reliability

## GoPro

The transport queues one logical request at a time. Bluetooth write completion
and the corresponding camera response must both arrive before the next request
starts. Command, settings, query, and network-management replies are separated;
unsolicited status and preset notifications cannot complete a request. Outgoing
messages are fragmented for CoreBluetooth's negotiated write length, including
GoPro continuation counters.

A missing ATT completion invalidates the connection. Capture requests also fail
and close the session if their camera acknowledgement times out, preventing a
late shutter response from being assigned to another capture request. Unsent
Start commands retain their existing expiration and Stop replacement behavior.
Read-only startup/status requests may recover after a response timeout. Mutating
commands are not automatically replayed by the transport.

Startup polls hardware information until success and retries read-only status
setup within the connection deadline. The app waits for successful hardware-info
and busy/encoding status before declaring readiness. First-time GoPro pairing
gets 90 seconds for system approval; ordinary reconnect deadlines stay bounded.

References: [Open GoPro BLE setup](https://gopro.github.io/OpenGoPro/docs/ble/protocol/ble_setup/)
and [GoEasyPro's response sequencing](https://github.com/sepp89117/GoEasyPro_Android/blob/eaec96b2c72e871ee32928a310325cfcebe410c9/app/src/main/java/com/sepp89117/goeasypro_android/gopro/GoProDevice.java).
The implementation is original Swift; GPL GoEasyPro code is not incorporated.

## DJI R SDK

Record, photo, and mode requests have a five-second maximum queued lifetime.
These requests set R SDK's response-required flag. Their three-second camera-ACK deadline starts when handed to CoreBluetooth,
not when first queued. A response must match both the sequence and command type.
Expired writes are discarded, late replies cannot revive expired intents, and
Stop cancels an unsent Start/photo request. A late Start acknowledgement cannot restore Starting after a newer Stop. Failures reach saved command history.

If the latest explicit Stop times out, is rejected, or loses its connection,
the store retains that Stop, closes the failed link, and issues a new Stop after
the camera's protocol is ready again. A newer capture request (including Start
still preparing Video mode) supersedes that recovery. Disconnect pauses it.
This recovery applies only to DJI's explicit Stop; uncertain Start, photo,
mode-change, and Insta360 toggle commands are never replayed automatically.

First-time pairing requests camera confirmation and allows 90 seconds for it.
An explicit camera rejection pauses automatic pairing attempts until a user
connects again. Stop delivery or acknowledgement does not establish stopped
recording; an R SDK status push supplies that state. Nano's separate DUML
pairing/control protocol is unchanged.

Reference: [Osmo Action Remote's verified Action 5 Pro notes](https://github.com/retweakeverything/osmo-action-remote/blob/cc3395455557677333a6acae5eb4a7e380a01eb6/docs/PROTOCOL.md).

## Insta360

[X5/X6 direct control](insta360-direct-control.md) uses model-specific frames and
explicit capture commands verified against published examples. Other models use
GPS Remote emulation. GPS Remote button sequences start at zero per connection,
advance by two, wrap at 256, and advance only after CoreBluetooth accepts a
notification. A backpressured command therefore retains the correct sequence.
Counters are separate for every camera and reset when its session is replaced.
After a shutter press, further shutter commands wait for feedback. A trailing recording timer does not reopen Stop during that window: a second Stop toggle could restart recording. Silence returns the state to unknown rather than claiming the camera stopped.

When the Stop feedback window expires, recent timer evidence still blocks Start,
photo, and toggle requests until that evidence becomes stale. Only a new timer
after the window ends can permit another Stop. Trailing timers do not publish a
Recording state during the Stop window, and expiry runs in common run-loop modes
so scrolling does not suspend the deadline.

The sequence behavior comes from [physical X4 remote observations](https://github.com/TheAngryRaven/insta360-ble-gps-spec/blob/7964f1133e5d0f2c7eb73aaaaf5d6ebdd2127199/README.md).
Applicability to other GPS Remote models is inferred from the shared packet
format, not verified on those cameras. The proposed continuous GPS liveness
stream is not implemented; its necessity is not established across models.

Multicam has not been tested on Insta360 hardware. Host checks replay documented
packets and exercise parser boundaries, command correlation, timeouts, fallback
eligibility, independent camera state, and superseded capture intents. These
checks do not establish radio behavior or compatibility with every firmware.
