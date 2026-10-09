# Privacy

Multicam is local-first.

- The app does not include analytics, advertising SDKs, or third-party network services.
- The app uses Bluetooth to discover and control nearby cameras.
- Remembered camera names, models, brands, and Bluetooth identifiers are stored locally on the device using `UserDefaults`.
- Recent diagnostic logs are saved locally across app restarts, up to 5 MB, with older entries removed when the archive reaches that limit. Clear beside Bluetooth Log removes the displayed and saved logs. They are excluded from device backups and stay on-device unless you choose to share them using Diagnostics > Share.

Diagnostic logs can include camera names, Bluetooth identifiers, advertised services, signal values, and command bytes. Review logs before posting them publicly.
