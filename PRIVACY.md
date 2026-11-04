# Privacy

Multicam is local-first.

- The app does not include analytics, advertising SDKs, or third-party network services.
- The app uses Bluetooth to discover and control nearby cameras.
- Remembered camera names, models, brands, Bluetooth identifiers, and app preferences are stored locally on the device using `UserDefaults`.
- When phone GPS is enabled for a supported camera, the app sends location data to that camera over Bluetooth so it can include GPS in its recordings.
- Recent Bluetooth logs are saved locally across app restarts, up to 5 MiB. Command results are saved separately, up to 500 entries or 512 KiB. Older entries are removed when either archive reaches its limit. Both archives are excluded from device backups. The Clear action beside each log in Diagnostics clears its displayed and saved entries.
- Logs stay on-device unless you choose to share them through Diagnostics > Share or Settings > Send Feedback. Send Feedback prepares an email to `multicam@dstrat.io` with the diagnostic export attached; you choose whether to send it. If Mail is unavailable, the app offers to share the same file through another app.

Diagnostic exports contain separate Bluetooth Log and Command Log sections. They can include camera names, Bluetooth identifiers, advertised services, signal values, command results, and command bytes. GPS payloads can contain location data when phone GPS is enabled. Review logs before sending or posting them publicly.
