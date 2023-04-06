# CloudSyncSession

![main branch CI status](https://github.com/ryanashcraft/CloudSyncSession/actions/workflows/CI.yml/badge.svg)

CloudSyncSession is a layer of abstraction on top of CloudKit that provides error handling and queueing for offline-capable apps.

Similar to `NSPersistentCloudKitContainer`, CloudSyncSession works for apps that need to sync all records in a zone between iCloud and the client. Unlike `NSPersistentCloudKitContainer`, which offers local persistence, CloudSyncSession does not persist state to disk in any way. As such, it can be used in conjunction with any local persistence solution (e.g. GRDB, Core Data, user defaults and file storage, etc.).

## Design Principles

1. Persistence-free. Data is not persisted to disk.
2. Testable. Code is structured in a way to maximize how much behavior can be tested.
3. Modular. To the extent that it makes sense, different behaviors are handled separately by different components.
4. Event-based. State is predictable, as it is updated based on the series of events that have previously occurred.
5. Resilient. Recoverable errors are gracefully handled using retries and backoffs. Non-recoverable errors halt further execution until the app signals that work should be resumed.
6. Focused. This project aims to solve a particular use case and do it well.

## Usage

1. Initialize the session.

```swift
static let storeIdentifier: String
static let zoneID: CKRecordZone.ID
static let subscriptionID: String
static let log: OSLog

static func makeSharedSession() -> CloudSyncSession {
    let container = CKContainer(identifier: Self.storeIdentifier)
    let database = container.privateCloudDatabase

    let session = CloudSyncSession(
        operationHandler: CloudKitOperationHandler(
            database: database,
            zoneID: Self.zoneID,
            subscriptionID: Self.subscriptionID,
            log: Self.log
        ),
        zoneID: Self.zoneID,
        resolveConflict: resolveConflict,
        resolveExpiredChangeToken: resolveExpiredChangeToken
    )

    session.appendMiddleware(
        AccountStatusMiddleware(
            session: session,
            ckContainer: container
        )
    )

    return session
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

cloudSyncSession.$state
    .sink { state in
        // Update UI with new sync state
    }

cloudSyncSession.eventsPublisher
    .sink { [weak self] event in
        // Update UI with most recent event
    }
```

## Under the Hood

CloudSyncSession is event-based. Events describe what has occurred, or what has been requested. The current state of the session is a result of the previous events up to that point.

CloudSyncSession uses the concept of event middleware in an effort to decouple and modularize independent behaviors. Middleware are ordered; they can transform events before they are passed along to the following middleware. They can also trigger side effects.

By default, the following middleware are initialized:

- `SplittingMiddleware`: Handles splitting up large work.
- `ErrorMiddleware`: Transforms CloudKit errors into a new event (e.g. `retry`, `halt`, `resolveConflict`, etc.).
- `RetryMiddleware`: Handles how to handle work that was marked to be retried.
- `WorkMiddleware`: Handles translating events into calls on the operation handler, and dispatches new events based on the result.
- `SubjectMiddleware`: Sends values to the various Combine subjects on the CloudSyncSession instance.
- `LoggerMiddleware`: Logs all events with os_log.
- `ZoneMiddleware`: On session start, dispatches events to queue work to create the zone and associated subscription.

In addition, the `AccountStatusMiddleware` is required, but not initialized by default. This middleware checks the account status on session start.

CloudSyncSession state transitions between different "operation modes" to determine which sort of work is to be handled: none (represented by `nil`), `createZone`, `createSubscription`, `modify`, and `fetch`. Work is queued up into separate queues, one for each operation mode. The state only operates in one operation mode at a time. Operation modes are made eligible or ineligible by certain events that occur (e.g. account status changes and errors). Operation modes are ordered, so work to create a zone always precedes work modification work, which likewise precedes fetch work.

## Tests

In an effort to make as much of the logic and behavior testable, most CloudKit-specific code is decoupled and/or mockable via protocols.

`OperationHandler` is a protocol that abstracts the handling all of the various operations: `FetchOperation`, `ModifyOperation`, `CreateZoneOperation`, and `CreateSubscriptionOperation`. The main implementation of this protocol, `CloudKitOperationHandler`, handles these operations using the standard CloudKit APIs.

There are two test suites: `CloudSyncSessionTests` and `SyncStateTests`. `CloudSyncSessionTests` uses custom `OperationHandler` instances to simulate different scenarios and test end-to-end behaviors, including retries, splitting up work, handling success and failure, etc.

`SyncStateTests` asserts that the state is correctly updated based on certain events.

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

The event-based architecture was heavily influenced by [Redux](https://github.com/reduxjs/redux).

## Contributions

I hope that you find this library helpful, either as a reference or as a solution for your app. In an effort to keep maintenance low and minimize risk, I am not interested in refactors, large changes, or expanding the scope of the capabilities that is offered. Please feel free to fork (see [LICENSE](./LICENSE.md)).

If you'd like to submit a bug fix or enhancement, please submit a pull request. Please include some context, your motivation, add tests if appropriate.

## License

See [LICENSE](/LICENSE.md).

Portions of this library were taken and modified from Cirrus, an MIT-licensed
library, Copyright (c) 2020 Jay Hickey. The code has been modified for use in
this project.
