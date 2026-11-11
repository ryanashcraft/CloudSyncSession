# CloudSyncSession

![main branch CI status](https://github.com/ryanashcraft/CloudSyncSession/actions/workflows/CI.yml/badge.svg)

CloudSyncSession is a Swift library that builds on top of the CloudKit framework to make it easier to write sync-enabled, offline-capable apps.

Similar to [NSPersistentCloudKitContainer](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer), CloudSyncSession works for apps that need to sync all records in a zone between iCloud and the client. Unlike NSPersistentCloudKitContainer, which offers local persistence, CloudSyncSession does not persist state to disk in any way. As such, it can be used in conjunction with any local persistence solution (e.g. GRDB, Core Data, user defaults and file storage, etc.).

## Design Principles

1. Persistence-free. Data is not persisted to disk.
2. Testable. Code is structured in a way to maximize how much behavior can be tested.
3. Modular. To the extent that it makes sense, different behaviors are handled separately by different components.
4. Sequential. One piece of work is in progress at a time, and what happens next is decided in one place, so the order of work is predictable.
5. Resilient. Recoverable errors are gracefully handled using retries and backoffs. Non-recoverable errors halt further execution until the app signals that work should be resumed.
6. Inspectable. The current state of the session can be evaluated for troubleshooting and diagnostics.
7. Focused. This project aims to solve a particular use case and do it well.

## Usage

1. Initialize the session.

```swift
static let storeIdentifier: String
static let zoneID: CKRecordZone.ID
static let subscriptionID: String

static func makeSharedSession() -> CloudSyncSession {
    let container = CKContainer(identifier: Self.storeIdentifier)
    let database = container.privateCloudDatabase

    return CloudSyncSession(
        operationHandler: CloudKitOperationHandler(
            database: database,
            zoneID: Self.zoneID,
            subscriptionID: Self.subscriptionID
        ),
        zoneID: Self.zoneID,
        // Asked for the iCloud account status whenever the session starts without knowing it
        accountStatusProvider: CloudSyncSession.accountStatusProvider(for: container),
        resolveConflict: resolveConflict,
        resolveExpiredChangeToken: resolveExpiredChangeToken
    )
}

static func resolveConflict(clientCkRecord: CKRecord, serverCkRecord: CKRecord) -> CKRecord? {
    // Implement your own conflict resolution logic

    if let clientDate = clientCkRecord.cloudKitLastModifiedDate,
        let serverDate = serverCkRecord.cloudKitLastModifiedDate
    {
        return clientDate > serverDate ? clientCkRecord : serverCkRecord
    }

    return clientCkRecord
}

static func resolveExpiredChangeToken() -> CKServerChangeToken? {
    // Update persisted store to reset the change token to nil

    return nil
}
```

2. Listen for changes.

```swift
// Listen for fetch work that has been completed
cloudSyncSession.fetchWorkCompletedSubject
    .map { _, response in
        (response.changeToken, response.changedRecords, response.deletedRecordIDs)
    }
    .sink { changeToken, ckRecords, recordIDsToDelete in
        // Process new and deleted records

        if let changeToken = changeToken {
            var newChangeTokenData: Data? = try NSKeyedArchiver.archivedData(
                withRootObject: changeToken as Any,
                requiringSecureCoding: true
            )

            // Save change token data to disk
        }
    }
```

```swift
// Listen for modification work that has been completed
cloudSyncSession.modifyWorkCompletedSubject
    .map { _, response in
        (response.changedRecords, response.deletedRecordIDs, userInfo)
    }
    .sink { ckRecords, recordIDsToDelete, userInfo in
        // Process new and deleted records
    }
```

3. Start the session.

```swift
cloudSyncSession.start()
```

4. Initiate a fetch.

```swift
// Obtain the change token from disk
let changeToken: CKServerChangeToken?

// Queue a fetch operation
cloudSyncSession.fetch(FetchOperation(changeToken: changeToken))
```

5. Initiate a modification.

```swift
let records: [CKRecord]
let recordIDsToDelete = [CKRecord.ID]
let checkpointID = UUID()
let operation = ModifyOperation(
    records: records,
    recordIDsToDelete: recordIDsToDelete,
    checkpointID: checkpointID,
    userInfo: nil
)

cloudSyncSession.modify(operation)
```

6. Handle CloudKit push notifications for live updates.

```swift
// AppDelegate.swift
func application(_: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    if let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
        notification.subscriptionID == Self.subscriptionID {
        // Initiate a fetch request with the most recent change token
        // Wait some time to see if that fetch operation finishes in time
        // Call completionHandler with the appropriate value

        return
    }

    // Handle other kinds of notifications
}
```

7. Observe changes and errors for user-facing diagnostics.

```swift
cloudSyncSession.haltedSubject
    .sink { error in
        // Update UI based on most recent error
    }

cloudSyncSession.accountStatusSubject
    .sink { accountStatus in
        // Update UI with new account status
    }

cloudSyncSession.statePublisher
    .sink { state in
        // Update UI with new sync state
    }

cloudSyncSession.eventsPublisher
    .sink { [weak self] event in
        // Update UI with most recent event
    }
```

8. Stop the session before destructive work.

```swift
// Cancels the operation in progress, if any, and returns once it has wound down,
// so nothing sent earlier can land after what you do next
await cloudSyncSession.stopAndWait()
cloudSyncSession.reset()

// Delete the zone, sign out, etc.
```

If the account status changes while the app is running, tell the session with `cloudSyncSession.accountStatusChanged(_:)`.

## Installation

To use CloudSyncSession with Swift Package Manager, add a dependency to https://github.com/ryanashcraft/CloudSyncSession

## Under the Hood

CloudSyncSession keeps four queues of work, one per kind: create zone, create subscription, modify, and fetch. They live in `SyncState`, which is also the snapshot published on `statePublisher`. Calls such as `modify(_:)`, `fetch(_:)`, `start()` and `stop()` change that state in one step, on the caller's thread, under a lock.

A single task, the run loop, does the work. It takes the piece of work at the head of the queue, hands it to the operation handler, waits for the result, updates the queue for that result, and only then looks at the queue again. Nothing else in the library starts work, so one operation is in progress at a time and the order is the order of the queue.

What the run loop does with a result:

- Success: the work leaves the queue and is reported on `fetchWorkCompletedSubject` or `modifyWorkCompletedSubject`. A fetch with more to come puts its next page first in line.
- A failure worth retrying (network, rate limiting, an expired change token): the loop waits, then sends the work again. Waits grow with each retry, and after five retries the session halts.
- A conflict: the app's conflict resolver runs and the batch is sent again with the resolved records.
- A request the server rejects as too large: it is sent again as two halves.
- A missing zone: the zone is created again, then the work is sent again.
- Anything else: the session halts and reports the error on `haltedSubject`. The work stays queued for the next `start()`.

In every case that sends work again, the replacement goes where the failed work was, ahead of everything queued after it.

The decisions are made by small pieces that do not touch the session, each of which can be tested on its own:

- `SyncState`: which work is next, and how the queues change for each outcome. Work to create the zone and the subscription always goes first. Modifies go before fetches, but the session finishes the kind of work it is doing before switching to the other. No work runs until the account is available, and no fetch or modify runs until the zone and subscription exist.
- `FailureResolver`: maps a CloudKit error to one of the outcomes above.
- `RetryPolicy`: how long to wait before a retry, and when to give up.
- `ModifyOperation.split` and `splitInHalf`: how a modify is divided.
- `Pacing`: how the session waits. The real one sleeps; tests substitute one that does not.

`eventsPublisher` announces each step (`doWork`, `workSuccess`, `workFailure`, `retry`, `halt`, and so on) once, for diagnostics. Events describe what happened; they do not drive the session.

`stop()` halts the session: no further work is sent, a wait before work or before a retry ends at once, and an operation that is with the operation handler is cancelled. `CloudKitOperationHandler` drops a cancelled request it has not sent yet and lets one that is already with CloudKit finish, because CloudKit cannot recall a request once it is sent. If the operation succeeds, that is reported. Otherwise its work stays queued for the next `start()`. `stopAndWait()` does the same and returns only when the cancelled operation has wound down, after which nothing the session sent can still reach the server. `reset()` cancels in the same way, discards the queues, and ignores the result of the operation that was in progress.

## Tests

In an effort to make as much of the logic and behavior testable, most CloudKit-specific code is decoupled and/or mockable via protocols.

`OperationHandler` is a protocol that abstracts the handling all of the various operations: `FetchOperation`, `ModifyOperation`, `CreateZoneOperation`, and `CreateSubscriptionOperation`. The main implementation of this protocol, `CloudKitOperationHandler`, handles these operations using the standard CloudKit APIs. Each of its methods is `async` and is cancelled when the session is stopped or reset.

`LiveTests` holds a separate set of tests that run against a real CloudKit container, for what the scripted handler cannot show. They are not part of `swift test`; see `LiveTests/README.md`.

Two suites describe the session purely from the outside, through `SessionHarness` and a `ScriptedOperationHandler` in `Tests/CloudSyncSessionTests/Support`. A test scripts how the handler replies, submits work, and asserts on the requests the handler received and the completions the session reported. These test files do not import the library, so they do not depend on how the session is built. The harness replaces the session's waits with ones that end at once, so retries and backoff are tested without waiting in real time, and it can hold a wait or a reply open to test what happens when the session is stopped or reset partway through.

- `SessionBehaviorTests`: behavior that must hold, such as ordering, retries, splitting, conflict resolution, and stopping.
- `SessionQueueInvariantTests`: seeded random mixes of operations checked against queue invariants.

The remaining suites test the pieces on their own:

- `SyncStateTests`: which work is chosen next, how the queues change for each outcome, and the retry policy.
- `SyncWorkTests`: how modify operations are split.
- `CloudKitSupportTests`: helpers that sit between the session and CloudKit.
- `SessionStateConcurrencyTests`: reading the state from several threads.

## Limitations

CloudSyncSession is not intended to be a drop-in solution to integrating CloudKit into your app. You need to correctly persist metadata and records to disk. In addition, you must use the appropriate hooks to convert your data models to and from CKRecords.

These CloudKit features are not supported:

- Shared records
- Assets
- Public databases
- References/relationships\*

Perhaps these features work in some capacity, but they are untested. If you are interested in these features and want to verify that they work, please do so and report back your learnings by filing an issue on GitHub.

\* I intentionally opted to not use references as it come with limited benefits and much more overhead for the sort of use case this library was designed for (mirroring data between iCloud and multiple clients).

## Influences

This library was heavily influenced by [Cirrus](https://github.com/jayhickey/Cirrus). Portions of this library were taken and modified by Cirrus.

I developed CloudSyncSession because there were a few things I was looking for in a CloudKit syncing library that Cirrus didn't offer.

- Cirrus requires instantiating separate sync engine instances – one for each record type. Each of these sync engines operate independently. I was concerned that for my use case, problems could arise if a sync engine for one record type would get out of sync with another. Particularly with entities that have implicit relationships. It seemed simpler, for my use case, to have a single stateful instance to orchestrate all syncing operations.
- Cirrus is clever in that it saves you the grief of converting to and from CKRecords, and instead allows you to interface directly with your existing model structs. However, in my case, I wanted the flexibility afforded from being able to use raw CKRecords.
- Many CloudKit libraries do not have much, if any, automated testing around the lifecycle and state management of the sync engine. CloudKit itself is extremely difficult to test in an automated fashion, because anything meaningful requires a device with a valid CloudKit account. I wanted some level of decoupling of CloudKit with the state management aspect of the library, so I could at least test most of the logic that didn't directly interface with CloudKit.

These are all tradeoffs. Cirrus is a great library and likely a better fit for many apps.

## Contributions

I hope that you find this library helpful, either as a reference or as a solution for your app. In an effort to keep maintenance low and minimize risk, I am not interested in large refactors or expanding the greatly scope of the capabilities currently offered. Please feel free to fork (see [LICENSE](./LICENSE.md)).

If you'd like to submit a bug fix or enhancement, please submit a pull request. Please include some context, your motivation, add tests if appropriate.

## License

See [LICENSE](/LICENSE.md).

Portions of this library were taken and modified from [Cirrus](https://github.com/jayhickey/Cirrus), an MIT-licensed library, Copyright (c) 2020 Jay Hickey. The code has been modified for use in this project.
