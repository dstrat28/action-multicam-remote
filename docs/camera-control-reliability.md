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

If the latest explicit GoPro or DJI Stop times out, is rejected, or loses its
connection before stopped status arrives, the store retains that Stop and issues
a new Stop after the camera's protocol is ready again. This includes loss after
command acknowledgement and loss after the advisory confirmation deadline, as
well as Bluetooth power-off and protocol-staleness disconnects. Reconnect Stop
gets a fresh confirmation window and repeated readiness does not dispatch it
twice. Trusted stopped status ends confirmation. A newer capture request
(including Start still preparing Video mode), Disconnect, or Remove supersedes
recovery. Uncertain Start, photo, mode-change, and Insta360 capture commands are
never automatically repeated by this recovery path.

First-time pairing requests camera confirmation and allows 90 seconds for it.
An explicit camera rejection pauses automatic pairing attempts until a user
connects again. Stop delivery or acknowledgement does not establish stopped
recording; an R SDK status push supplies that state. Nano's separate DUML
pairing/control protocol is unchanged.

Nano's DUML Stop acknowledgement also means acceptance, not completed Stop.
Only camera status confirms that recording stopped. An explicit Stop releases
the prior Start's stale-stopped guard, so even a short recording can confirm
promptly. Nano keeps its existing 15-second confirmation window, ending as soon
as trusted stopped status arrives. If that deadline expires, the app shows
“Stop not confirmed” and permits another explicit action.

Reference: [Osmo Action Remote's verified Action 5 Pro notes](https://github.com/retweakeverything/osmo-action-remote/blob/cc3395455557677333a6acae5eb4a7e380a01eb6/docs/PROTOCOL.md).

## Insta360

[X5/X6 direct control](insta360-direct-control.md) uses model-specific frames and
explicit capture commands verified against published examples. Other models use
GPS Remote emulation. GPS Remote button sequences start at zero per connection,
advance by two, wrap at 256, and advance only after CoreBluetooth accepts a
notification. A backpressured command therefore retains the correct sequence.
Counters are separate for every camera and reset when its session is replaced.
After a shutter press, further shutter commands wait for feedback. A trailing recording timer does not reopen Stop during that window: a second Stop toggle could restart recording. Silence returns the state to unknown rather than claiming the camera stopped.

The Stop feedback cooldown lasts five seconds. Trailing timers do not extend it
or block a new explicit Record/photo/toggle afterward; no stopped-state confirmation
is required for that next action. A fresh timer after the cooldown can establish
Recording again and permit another Stop. No shutter action is repeated automatically.
Five seconds does not confirm Stop: a new shutter press can stop an ongoing
recording if the previous Stop failed.
Expiry runs in common run-loop modes so scrolling does not suspend the deadline.
When Bluetooth queues Stop, the UI's cooldown starts when the queued command is
actually transmitted. It uses the same duration as the transport; duplicate or
superseded delivery callbacks cannot extend the wait. Recording timers while
Stop is still queued keep Recording visible and cannot cancel its pending UI.

The app's Stop spinner ends after five seconds for GPS Remote. Other cameras
wait for stopped status, with a 15-second fallback to an advisory “Stop not
confirmed”; a late trusted stopped status clears it. GPS Remote returns
to the green connection display because it cannot explicitly confirm Stop, while
its underlying recording state remains unknown. Missing confirmation adds no new
recording lockout.

The sequence behavior comes from [physical X4 remote observations](https://github.com/TheAngryRaven/insta360-ble-gps-spec/blob/7964f1133e5d0f2c7eb73aaaaf5d6ebdd2127199/README.md).
Applicability to other GPS Remote models is inferred from the shared packet
format, not verified on those cameras. The proposed continuous GPS liveness
stream is not implemented; its necessity is not established across models.

Multicam has not been tested on Insta360 hardware. Host checks replay documented
packets and exercise parser boundaries, command correlation, timeouts, fallback
eligibility, independent camera state, and superseded capture intents. These
checks do not establish radio behavior or compatibility with every firmware.
