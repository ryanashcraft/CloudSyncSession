import CloudKit
import Foundation

/// The state of a session.
public struct SyncState {
    /// The various modes that the session can be operating in.
    public enum OperationMode {
        case modify
        case fetch
        case createZone
        case createSubscription
    }

    /// The queue of modification requests to be handled.
    var modifyQueue = [ModifyOperation]()

    /// The queue of fetch requests to be handled.
    var fetchQueue = [FetchOperation]()

    /// The queue of create zone requests to be handled.
    var createZoneQueue = [CreateZoneOperation]()

    /// The queue of create subscription requests to be handled.
    var createSubscriptionQueue = [CreateSubscriptionOperation]()

    /// Indicates whether the CloudKit status is available. The value is nil if the account status is yet to be deteremined.
    public var hasGoodAccountStatus: Bool? = nil

    /// Indicates whether the zone has been created. The value is nil if the session has yet to create the zone.
    public var hasCreatedZone: Bool? = nil

    /// Indicates whether the subscription has been created. The value is nil if the session has yet to create the subscription.
    public var hasCreatedSubscription: Bool? = nil

    /// Indicates whether the sync session has halted.
    public var isHalted: Bool = false {
        didSet {
            lastHaltedDate = isHalted ? Date() : nil

            updateOperationMode()
        }
    }

    /// The time at which the sync session was last halted.
    public var lastHaltedDate: Date?

    /// How many times the current work has been retried.
    public var retryCount: Int = 0

    /// The error that caused the last retry.
    public var lastRetryError: Error?

    /// Indicates whether the session is currently modyifing, fetching, creating a zone, or creating a subscription.
    public var operationMode: OperationMode?

    /// Indicates whether or not there's any work to be done.
    public var hasWorkQueued: Bool {
        !modifyQueue.isEmpty || !fetchQueue.isEmpty || !createZoneQueue.isEmpty || !createSubscriptionQueue.isEmpty
    }

    /// Indicates whether the session is currently fetching.
    public var isFetching: Bool {
        operationMode == .fetch
    }

    /// Indicates whether the session is currently modifying.
    public var isModifying: Bool {
        operationMode == .modify
    }

    /// Indicates what kind of work is allowed at this time.
    var allowedOperationModes: Set<OperationMode?> {
        var allowedModes: Set<OperationMode?> = [nil]

        if isHalted {
            // Halted means no work allowed
            return allowedModes
        }

        if !(hasGoodAccountStatus ?? false) {
            // Bad or unknown account status means no work allowed
            return allowedModes
        }

        allowedModes.formUnion([.createZone, .createSubscription])

        if hasCreatedZone ?? false, hasCreatedSubscription ?? false {
            allowedModes.formUnion([.fetch, .modify])
        }

        return allowedModes
    }

    /// An ordered list of the the kind of work that is allowed at this time.
    var preferredOperationModes: [OperationMode?] {
        [.createZone, .createSubscription, .modify, .fetch, nil]
            .filter { allowedOperationModes.contains($0) }
            .filter { mode in
                switch mode {
                case .createZone:
                    return !createZoneQueue.isEmpty
                case .fetch:
                    return !fetchQueue.isEmpty
                case .modify:
                    return !modifyQueue.isEmpty
                case .createSubscription:
                    return !createSubscriptionQueue.isEmpty
                case nil:
                    return true
                }
            }
    }

    /// Indicates whether the session is ready to perform fetches and modifications.
    public var isRunning: Bool {
        allowedOperationModes.contains(.fetch)
            && allowedOperationModes.contains(.modify)
            && !isHalted
    }

    /// Indicates whether the prerequisites have been met to fetch and/or modify records.
    public var hasStarted: Bool {
        hasCreatedZone != nil && hasCreatedSubscription != nil && hasGoodAccountStatus != nil
    }

    /// Indicates whether we are starting up, but not ready to fetch and/or modify records.
    public var isStarting: Bool {
        !hasStarted && !isHalted
    }

    /// The current work that is, or is to be, worked on.
    var currentWork: SyncWork? {
        guard allowedOperationModes.contains(operationMode) else {
            return nil
        }

        switch operationMode {
        case nil:
            return nil
        case .modify:
            if let operation = modifyQueue.first {
                return SyncWork.modify(operation)
            }
        case .fetch:
            if let operation = fetchQueue.first {
                return SyncWork.fetch(operation)
            }
        case .createZone:
            if let operation = createZoneQueue.first {
                return SyncWork.createZone(operation)
            }
        case .createSubscription:
            if let operation = createSubscriptionQueue.first {
                return SyncWork.createSubscription(operation)
            }
        }

        return nil
    }

    /// Transition to a new operation mode (i.e. fetching, modifying creating a zone or subscription)
    mutating func updateOperationMode() {
        if isHalted {
            operationMode = nil
        }

        let preferredModes = preferredOperationModes
        let mostPreferredMode = preferredModes.first ?? nil

        // Creating the zone or the subscription always goes first, because fetches and modifies
        // depend on them. Otherwise the session stays in its current mode until that queue is empty.
        let mustSetUpFirst = mostPreferredMode == .createZone || mostPreferredMode == .createSubscription

        if mustSetUpFirst || operationMode == nil || !preferredModes.contains(operationMode) {
            operationMode = mostPreferredMode
        }
    }

    /// Add work to the end of the appropriate queue
    mutating func pushWork(_ work: SyncWork) {
        switch work {
        case let .fetch(operation):
            fetchQueue.append(operation)
        case let .modify(operation):
            modifyQueue.append(operation)
        case let .createZone(operation):
            createZoneQueue.append(operation)
        case let .createSubscription(operation):
            createSubscriptionQueue.append(operation)
        }
    }

    /// Add work to the beginning of the appropriate queue.
    mutating func prioritizeWork(_ work: SyncWork) {
        switch work {
        case let .fetch(operation):
            fetchQueue = [operation] + fetchQueue
        case let .modify(operation):
            modifyQueue = [operation] + modifyQueue
        case let .createZone(operation):
            createZoneQueue = [operation] + createZoneQueue
        case let .createSubscription(operation):
            createSubscriptionQueue = [operation] + createSubscriptionQueue
        }
    }

    /// Remove work from the corresponding queue.
    mutating func popWork(work: SyncWork) {
        switch work {
        case let .fetch(operation):
            fetchQueue = fetchQueue.filter { $0.id != operation.id }
        case let .modify(operation):
            modifyQueue = modifyQueue.filter { $0.id != operation.id }
        case let .createZone(operation):
            createZoneQueue = createZoneQueue.filter { $0.id != operation.id }
        case let .createSubscription(operation):
            createSubscriptionQueue = createSubscriptionQueue.filter { $0.id != operation.id }
        }
    }

    /// Whether the work is still in its queue. It is not after the session has been reset.
    func contains(_ work: SyncWork) -> Bool {
        switch work {
        case let .fetch(operation):
            return fetchQueue.contains { $0.id == operation.id }
        case let .modify(operation):
            return modifyQueue.contains { $0.id == operation.id }
        case let .createZone(operation):
            return createZoneQueue.contains { $0.id == operation.id }
        case let .createSubscription(operation):
            return createSubscriptionQueue.contains { $0.id == operation.id }
        }
    }

    /// Whether a fetch from this change token is already waiting or under way.
    func hasQueuedFetch(from changeToken: CKServerChangeToken?) -> Bool {
        fetchQueue.contains { $0.changeToken == changeToken }
    }

    /// Add work to the end of its queue and pick it up if nothing else is under way.
    mutating func enqueue(_ work: SyncWork) {
        pushWork(work)
        updateOperationMode()
    }

    /// Put other work in the place of work that is in a queue, keeping its position.
    private mutating func replaceWork(_ work: SyncWork, with replacements: [SyncWork]) {
        switch work {
        case let .fetch(operation):
            if let index = fetchQueue.firstIndex(where: { $0.id == operation.id }) {
                fetchQueue.replaceSubrange(index ... index, with: replacements.compactMap {
                    if case let .fetch(replacement) = $0 { return replacement } else { return nil }
                })
            }
        case let .modify(operation):
            if let index = modifyQueue.firstIndex(where: { $0.id == operation.id }) {
                modifyQueue.replaceSubrange(index ... index, with: replacements.compactMap {
                    if case let .modify(replacement) = $0 { return replacement } else { return nil }
                })
            }
        case let .createZone(operation):
            if let index = createZoneQueue.firstIndex(where: { $0.id == operation.id }) {
                createZoneQueue.replaceSubrange(index ... index, with: replacements.compactMap {
                    if case let .createZone(replacement) = $0 { return replacement } else { return nil }
                })
            }
        case let .createSubscription(operation):
            if let index = createSubscriptionQueue.firstIndex(where: { $0.id == operation.id }) {
                createSubscriptionQueue.replaceSubrange(index ... index, with: replacements.compactMap {
                    if case let .createSubscription(replacement) = $0 { return replacement } else { return nil }
                })
            }
        }
    }

    /// Update the queues for how an attempt at `work` ended. Work that is tried again, resent, or
    /// split keeps its place: whatever replaces it goes where it was.
    ///
    /// Returns false and changes nothing if the work is no longer queued.
    @discardableResult
    mutating func apply(_ outcome: WorkOutcome, to work: SyncWork) -> Bool {
        guard contains(work) else {
            return false
        }

        switch outcome {
        case let .succeeded(result):
            retryCount = 0
            lastRetryError = nil

            popWork(work: work)

            switch result {
            case let .fetch(response):
                if response.hasMore {
                    prioritizeWork(.fetch(FetchOperation(changeToken: response.changeToken)))
                }
            case let .createZone(didCreateZone):
                hasCreatedZone = didCreateZone
            case let .createSubscription(didCreateSubscription):
                hasCreatedSubscription = didCreateSubscription
            case .modify:
                break
            }
        case let .retryScheduled(error):
            retryCount += 1
            lastRetryError = error
        case let .retrying(workToRetry):
            replaceWork(work, with: [workToRetry.retried])
        case let .replaced(operations):
            replaceWork(work, with: operations.map(SyncWork.modify))
        case let .zoneMissing(createZoneOperation):
            replaceWork(work, with: [work.retried])

            if createZoneQueue.isEmpty {
                createZoneQueue.append(createZoneOperation)
            }
        }

        updateOperationMode()

        return true
    }
}

/// How one attempt at a piece of work ended, as far as the queues are concerned.
enum WorkOutcome {
    /// The work finished and leaves its queue. A fetch with more to come puts the next page first in line.
    case succeeded(SyncWork.Result)

    /// The work failed and will be tried again after a wait. It stays where it is.
    case retryScheduled(Error)

    /// The wait is over. The work to retry takes the failed work's place with its retry count raised.
    case retrying(SyncWork)

    /// These modify operations take the failed work's place, in order.
    case replaced([ModifyOperation])

    /// The zone is gone. The operation that recreates it is queued unless one already is, and the
    /// failed work stays where it is with its retry count raised.
    case zoneMissing(CreateZoneOperation)
}
