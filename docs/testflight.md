# TestFlight

This project distributes beta builds through App Store Connect and Xcode Cloud.

Public App Store link: https://apps.apple.com/us/app/action-multicam-remote/id6784017391

## App Metadata

- App Store Connect name: `Action Multicam Remote`
- App display name: `Multicam`
- Bundle ID: `com.ds.ActionCamRemote`
- App Store Connect app ID: `6784017391`
- SKU: `action-multicam-ios`
- Team ID: `2WX2Z9452K`

## Release Flow

The normal release path is:

1. Push the release commit to `main`; this starts the configured Xcode Cloud workflow.
2. For an explicit TestFlight rollout, create and push the next sequential `testflight-0.1.N` tag on that same commit. The tag is a release marker, not the app's marketing version.
3. Let Xcode Cloud archive the app.
4. Wait for App Store Connect to finish processing the build.
5. Add the processed build to the desired TestFlight group.
6. Submit for Beta App Review when required.

Xcode Cloud owns the build number for cloud archives. If App Store Connect rejects a build-number collision, update the workflow's next build number in App Store Connect under Xcode Cloud > Settings > Build Number, then push a new commit.

## Local Fallback

Prefer Xcode Cloud. If a local archive is needed, create an iOS archive in Xcode Organizer or use:

```sh
xcodebuild \
  -project ActionCamRemote.xcodeproj \
  -scheme ActionCamRemote \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/action-multicam.xcarchive \
  DEVELOPMENT_TEAM=2WX2Z9452K \
  -allowProvisioningUpdates \
  clean archive
```

Export with:

```sh
xcodebuild \
  -exportArchive \
  -archivePath /tmp/action-multicam.xcarchive \
  -exportPath /tmp/action-multicam-testflight-export \
  -exportOptionsPlist ci/TestFlightExportOptions.plist \
  -allowProvisioningUpdates
```

If signing assets cannot be created automatically, open Xcode, sign in under Settings > Accounts, and retry from Organizer.
