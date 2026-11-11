# Live CloudKit tests

The package's own tests script the operation handler, so they cannot tell how CloudKit itself behaves. These tests run against a real CloudKit container. They are not part of `swift test` or CI: CloudKit needs an app with an iCloud entitlement and a device signed in to iCloud.

Run them before releasing a change to how `CloudKitOperationHandler` drives CloudKit.

## What they check

- `CancellationProbeTests`: what a cancelled `CKModifyRecordsOperation` and `CKFetchRecordZoneChangesOperation` do. Does the completion block still run, with which error, and does a cancelled modify still reach the server? These tests record what they see (lines starting `LIVE-OBSERVATION`) and fail only if an operation never finishes.
- `ErrorShapeTests`: that a conflict on one record of a batch arrives as a `partialFailure` carrying per-record errors, which the session's conflict handling depends on, and what a fetch from a deleted zone reports.
- `StopAndWaitTests`: that after `stopAndWait()` and deleting the zone, nothing the session sent earlier brings the zone back.

## Setup

1. Copy `Local.xcconfig.example` to `Local.xcconfig` and fill in the team, a bundle identifier, and a CloudKit container kept for these tests.
2. Generate the project: `xcodegen generate` (in this directory).
3. The Mac or device must be signed in to iCloud. A device must also be paired, unlocked, and in Developer Mode.

## Running

On this Mac:

```bash
xcodebuild test -project LiveTests.xcodeproj -scheme LiveTests -destination 'platform=macOS' -allowProvisioningUpdates
```

On a device (find its identifier with `xcrun devicectl list devices`):

```bash
xcodebuild test -project LiveTests.xcodeproj -scheme LiveTests -destination 'platform=iOS,id=DEVICE-IDENTIFIER' -allowProvisioningUpdates
```

`-allowProvisioningUpdates` lets Xcode register the bundle identifier and container with the team if they are new.

The tests use the Development environment and only zones they create (named `LiveTests-…`), which they delete when they finish.

## What they have shown

Recorded on 2026-11-11 on macOS 27.0 with Xcode 27.0. Not yet run on iOS.

- A cancelled `CKModifyRecordsOperation` calls `modifyRecordsCompletionBlock` with `CKError.operationCancelled`, whether it is cancelled before it starts or while it is executing. The block runs before the operation is marked finished.
- A cancelled `CKFetchRecordZoneChangesOperation` calls `fetchRecordZoneChangesResultBlock` with `operationCancelled` in both cases too. Its per-zone result block does not run.
- A modify of 200 records cancelled about 20 ms after it began executing left no records on the server. That is one observation of a race, not a guarantee: a cancelled modify can still have been committed.
- A conflict on one record of a two-record batch arrives as `partialFailure` with `serverRecordChanged` for the conflicted record, carrying the server's copy, and `batchRequestFailed` for the other.
- A fetch from a deleted zone fails with `zoneNotFound`.
- With a modify in progress, `stopAndWait()` returned after about half a second, and the zone, deleted straight afterwards, had not come back five seconds later.

A Mac app must state `com.apple.developer.icloud-container-environment` in its entitlements. Without it every CloudKit call failed with "Couldn't get container configuration from the server". The project sets it to `Development`.
