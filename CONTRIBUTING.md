# Contributing

Thanks for helping make Multicam better.

## Development

Use Xcode 15 or newer and build the `ActionCamRemote` scheme. Simulator builds are useful for UI work, but hardware features require a physical iPhone or iPad because iOS Simulator cannot connect to real Bluetooth cameras.

```sh
xcodebuild \
  -project ActionCamRemote.xcodeproj \
  -scheme ActionCamRemote \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Hardware Reports

Camera behavior varies by model, firmware, and power state. Good reports include:

- camera model and firmware version;
- iOS/iPadOS version;
- whether the camera was on, asleep, or off;
- whether the app showed Connected, Available, or Not Connected;
- what command was sent;
- what happened on the physical camera;
- copied diagnostics if you are comfortable sharing them.

Review diagnostics before posting publicly. They may contain Bluetooth identifiers, camera names, service UUIDs, and raw command bytes.

## Protocol Work

GoPro changes should follow the public Open GoPro BLE API. DJI Action/360 control uses DJI's R SDK handshake and status protocol, with model-scoped DUML commands where behavior differs between cameras.

Keep model-specific behavior isolated, preserve the shared connection flow, and include regression coverage for packet encoding or state parsing changes. Mark a camera as hardware-tested only after verifying it on a physical device.

For signed device builds, select your own Apple development team in Xcode and use bundle identifiers registered to that team. The repository's bundle identifiers belong to the published app and do not grant access to its signing credentials.
