# TestFlight

This project can be archived locally for TestFlight with Xcode command-line tools.

## Current App Metadata

- App display name: `Multicam`
- Bundle ID: `com.ds.ActionCamRemote`
- Version: `0.1`
- Build: `1`
- Team ID used for local archive attempts: `2WX2Z9452K`

## App Store Connect Setup

Before uploading a build, create an App Store Connect app record that matches the bundle ID:

- Platform: iOS
- Name: Multicam, or Action Multicam if `Multicam` is unavailable
- Bundle ID: `com.ds.ActionCamRemote`
- SKU: `action-multicam-ios`
- Primary language: English

The first upload attempt on June 24, 2026 successfully archived the app, but App Store Connect returned zero apps for `com.ds.ActionCamRemote`, so upload could not continue until this app record exists.

## Archive

```sh
xcodebuild \
  -project ActionCamRemote.xcodeproj \
  -scheme ActionCamRemote \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/action-multicam-0.1-1.xcarchive \
  DEVELOPMENT_TEAM=2WX2Z9452K \
  -allowProvisioningUpdates \
  clean archive
```

## Upload

After the App Store Connect app record exists, upload the archive:

```sh
xcodebuild \
  -exportArchive \
  -archivePath /tmp/action-multicam-0.1-1.xcarchive \
  -exportPath /tmp/action-multicam-testflight-export \
  -exportOptionsPlist ci/TestFlightExportOptions.plist \
  -allowProvisioningUpdates
```

If Xcode cannot create distribution signing assets automatically, open Xcode, sign in under Settings > Accounts, and retry the upload from Organizer or with the same command.

## Public TestFlight Link

Once the build appears in App Store Connect:

1. Add internal testers first to smoke-test the uploaded build.
2. Create an external tester group.
3. Complete Test Information and submit the first external build for Beta App Review.
4. After approval, enable Public Link for the external group.
5. Replace the placeholder link in `README.md` with the generated `https://testflight.apple.com/join/...` URL.

