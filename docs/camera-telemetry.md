# Camera battery and storage

Tap a connected camera to open Camera Info. Media & Battery shows optional readings
provided by that camera's control protocol. Storage values display free space only,
for example `32GB free`, with no total-capacity suffix.

| Connection | Readings |
| --- | --- |
| Insta360 SDK, X6 | Battery/power plus separate Internal Storage and SD Card rows. Each successful volume response stands alone; capacities are never added together or presented as a primary destination. |
| Insta360 SDK, other supported models | Battery/power and the reported SD-card capacity/status. |
| DJI Nano | Internal free space from full DUML status; battery/power from the compact variant when reported. The dock's card is for export. |
| DJI R SDK | Camera battery and the single documented remaining-capacity field. The protocol does not supply a second internal-storage reading. |
| GoPro | Existing battery/power and remaining-storage statuses, with KiB converted consistently even below one MiB. |
| Insta360 GPS Remote | Battery and storage are unavailable on this protocol. |

A missing SD card is shown as Not inserted only when explicitly reported. Full
cards retain a valid zero-free reading; invalid capacities are unavailable. Missing
or ambiguous volume entries are omitted. A new SDK storage snapshot replaces the
previous one, so a partial response cannot retain a stale second volume.

Battery/storage queries do not confirm capture, change readiness, or gate Start
and Stop. Insta360 metadata keeps its independent five-second display deadline,
one outstanding request and 30-second cadence. A Nano status-poll response can
refresh metadata but cannot update capture state/mode or advance recording-timer
evidence; live state pushes retain capture confirmation.

See [UI captures and reproduction](design-qa/camera-metadata/README.md). Host
regressions use protocol fixtures/SDK doubles; they do not establish hardware
compatibility or firmware behavior.
