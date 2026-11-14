import Foundation

/// The state of a session.
public struct SessionState<Backend: SyncBackend>: Sendable {
    /// The various modes that the session can be operating in.
    public enum OperationMode: Hashable, Sendable {
        case modify
        case fetch
        case setup(Backend.SetupStep)
    }

    /// The queue of modification requests to be handled.
    var modifyQueue = [SessionModifyOperation<Backend>]()

    /// The queue of fetch requests to be handled.
    var fetchQueue = [SessionFetchOperation<Backend>]()

    /// The queue of setup requests to be handled.
    var setupQueue = [SessionSetupOperation<Backend>]()

    /// Indicates whether the account can be used. The value is nil if the account status is yet to be deteremined.
    public internal(set) var hasGoodAccountStatus: Bool? = nil

    /// For each setup step the session has attempted, whether it is in place. A step is missing
    /// from the dictionary until the session has an answer for it.
    public internal(set) var setupResults = [Backend.SetupStep: Bool]()

    /// Indicates whether the sync session has halted.
    public internal(set) var isHalted: Bool = false {
        didSet {
            lastHaltedDate = isHalted ? Date() : nil

            updateOperationMode()
        }
    }

    /// The time at which the sync session was last halted.
    public internal(set) var lastHaltedDate: Date?

    /// How many times the current work has been retried.
    public internal(set) var retryCount: Int = 0

    /// The error that caused the last retry.
    public internal(set) var lastRetryError: Error?

    /// Indicates whether the session is currently modyifing, fetching, or setting up.
    public internal(set) var operationMode: OperationMode?

    public init() {}

    /// Indicates whether or not there's any work to be done.
    public var hasWorkQueued: Bool {
        !modifyQueue.isEmpty || !fetchQueue.isEmpty || !setupQueue.isEmpty
    }

    /// Indicates whether the session is currently fetching.
    public var isFetching: Bool {
        operationMode == .fetch
    }

    /// Indicates whether the session is currently modifying.
    public var isModifying: Bool {
        operationMode == .modify
    }

    /// Indicates whether every setup step is in place.
    var isSetUp: Bool {
        Backend.setupSteps.allSatisfy { setupResults[$0] == true }
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

        allowedModes.formUnion(Backend.setupSteps.map { .setup($0) })

        if isSetUp {
            allowedModes.formUnion([.fetch, .modify])
        }

        return allowedModes
    }

    /// An ordered list of the the kind of work that is allowed at this time.
    var preferredOperationModes: [OperationMode?] {
        let allowedModes = allowedOperationModes
        let modesInOrder: [OperationMode?] = Backend.setupSteps.map { .setup($0) } + [.modify, .fetch, nil]

        return modesInOrder
            .filter { allowedModes.contains($0) }
            .filter { mode in
                switch mode {
                case let .setup(step):
                    return hasQueuedSetup(of: step)
                case .fetch:
                    return !fetchQueue.isEmpty
                case .modify:
                    return !modifyQueue.isEmpty
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
        Backend.setupSteps.allSatisfy { setupResults[$0] != nil } && hasGoodAccountStatus != nil
    }

    /// Indicates whether we are starting up, but not ready to fetch and/or modify records.
    public var isStarting: Bool {
        !hasStarted && !isHalted
    }

    /// The current work that is, or is to be, worked on.
    var currentWork: SessionWork<Backend>? {
        guard allowedOperationModes.contains(operationMode) else {
            return nil
        }

        switch operationMode {
        case nil:
            return nil
        case .modify:
            if let operation = modifyQueue.first {
                return .modify(operation)
            }
        case .fetch:
            if let operation = fetchQueue.first {
                return .fetch(operation)
            }
        case let .setup(step):
            if let operation = setupQueue.first(where: { $0.step == step }) {
                return .setup(operation)
            }
        }

        return nil
    }

    /// Transition to a new operation mode (i.e. fetching, modifying, or setting up)
    mutating func updateOperationMode() {
        if isHalted {
            operationMode = nil
        }

        let preferredModes = preferredOperationModes
        let mostPreferredMode = preferredModes.first ?? nil

        // Setup always goes first, because fetches and modifies depend on it. Otherwise the
        // session stays in its current mode until that queue is empty.
        var mustSetUpFirst = false

        if case .setup = mostPreferredMode {
            mustSetUpFirst = true
        }

        if mustSetUpFirst || operationMode == nil || !preferredModes.contains(operationMode) {
            operationMode = mostPreferredMode
        }
    }

    /// Add work to the end of the appropriate queue
    mutating func pushWork(_ work: SessionWork<Backend>) {
        switch work {
        case let .fetch(operation):
            fetchQueue.append(operation)
        case let .modify(operation):
            modifyQueue.append(operation)
        case let .setup(operation):
            setupQueue.append(operation)
        }
    }

    /// Add work to the beginning of the appropriate queue.
    mutating func prioritizeWork(_ work: SessionWork<Backend>) {
        switch work {
        case let .fetch(operation):
            fetchQueue = [operation] + fetchQueue
        case let .modify(operation):
            modifyQueue = [operation] + modifyQueue
        case let .setup(operation):
            setupQueue = [operation] + setupQueue
        }
    }

    /// Remove work from the corresponding queue.
    mutating func popWork(work: SessionWork<Backend>) {
        switch work {
        case let .fetch(operation):
            fetchQueue = fetchQueue.filter { $0.id != operation.id }
        case let .modify(operation):
            modifyQueue = modifyQueue.filter { $0.id != operation.id }
        case let .setup(operation):
            setupQueue = setupQueue.filter { $0.id != operation.id }
        }
    }

    /// Whether the work is still in its queue. It is not after the session has been reset.
    func contains(_ work: SessionWork<Backend>) -> Bool {
        switch work {
        case let .fetch(operation):
            return fetchQueue.contains { $0.id == operation.id }
        case let .modify(operation):
            return modifyQueue.contains { $0.id == operation.id }
        case let .setup(operation):
            return setupQueue.contains { $0.id == operation.id }
        }
    }

    /// Whether any work a `perform` call queued is still in a queue.
    func hasWork(performID: UUID) -> Bool {
        modifyQueue.contains { $0.performID == performID } || fetchQueue.contains { $0.performID == performID }
    }

    /// The `perform` calls that have work in a queue.
    var queuedPerformIDs: Set<UUID> {
        Set(modifyQueue.compactMap(\.performID) + fetchQueue.compactMap(\.performID))
    }

    /// Take the work a `perform` call queued out of the queues, apart from the one piece with the
    /// given ID: a request the backend already has cannot be taken back. A fetch that `fetch(_:)`
    /// asked for as well stays queued and no longer belongs to the call.
    mutating func withdrawWork(performID: UUID, except workInFlightID: UUID?) {
        modifyQueue.removeAll { $0.performID == performID && $0.id != workInFlightID }
        fetchQueue.removeAll { $0.performID == performID && $0.id != workInFlightID && !$0.isAlsoQueuedByFetch }

        for index in fetchQueue.indices where fetchQueue[index].performID == performID && fetchQueue[index].id != workInFlightID {
            fetchQueue[index].performID = nil
            fetchQueue[index].isAlsoQueuedByFetch = false
        }

        updateOperationMode()
    }

    /// Records that `fetch(_:)` was asked for a fetch that is already queued from this change token.
    mutating func noteFetchAlsoQueued(from changeToken: Backend.ChangeToken?) {
        for index in fetchQueue.indices where fetchQueue[index].changeToken == changeToken && fetchQueue[index].performID != nil {
            fetchQueue[index].isAlsoQueuedByFetch = true
        }
    }

    /// Whether a fetch from this change token is already waiting or under way.
    func hasQueuedFetch(from changeToken: Backend.ChangeToken?) -> Bool {
        fetchQueue.contains { $0.changeToken == changeToken }
    }

    /// Whether work to put this setup step in place is already waiting or under way.
    func hasQueuedSetup(of step: Backend.SetupStep) -> Bool {
        setupQueue.contains { $0.step == step }
    }

    /// Add work to the end of its queue and pick it up if nothing else is under way.
    mutating func enqueue(_ work: SessionWork<Backend>) {
        pushWork(work)
        updateOperationMode()
    }

    /// Put other work in the place of work that is in a queue, keeping its position.
    private mutating func replaceWork(_ work: SessionWork<Backend>, with replacements: [SessionWork<Backend>]) {
        // Stamped here so that work a backend builds for a retry cannot lose it.
        let replacements = replacements.map { replacement in
            var replacement = replacement

            replacement.performID = work.performID

            if case let .fetch(replaced) = work, case var .fetch(operation) = replacement {
                operation.isAlsoQueuedByFetch = replaced.isAlsoQueuedByFetch
                replacement = .fetch(operation)
            }

            return replacement
        }

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
        case let .setup(operation):
            if let index = setupQueue.firstIndex(where: { $0.id == operation.id }) {
                setupQueue.replaceSubrange(index ... index, with: replacements.compactMap {
                    if case let .setup(replacement) = $0 { return replacement } else { return nil }
                })
            }
        }
    }

    /// Update the queues for how an attempt at `work` ended. Work that is tried again, resent, or
    /// split keeps its place: whatever replaces it goes where it was.
    ///
    /// Returns false and changes nothing if the work is no longer queued.
    @discardableResult
    mutating func apply(_ outcome: WorkOutcome<Backend>, to work: SessionWork<Backend>) -> Bool {
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
                    prioritizeWork(.fetch(SessionFetchOperation(changeToken: response.changeToken)))
                }
            case let .setup(isInPlace):
                if case let .setup(operation) = work {
                    setupResults[operation.step] = isInPlace
                }
            case .modify:
                break
            }
        case let .retryScheduled(error):
            retryCount += 1
            lastRetryError = error
        case let .retrying(workToRetry):
            replaceWork(work, with: [workToRetry.retried])
        case let .replaced(operations):
            replaceWork(work, with: operations.map(SessionWork.modify))
        case let .setupMissing(setupOperation):
            replaceWork(work, with: [work.retried])

            if !hasQueuedSetup(of: setupOperation.step) {
                setupQueue.append(setupOperation)
            }
        }

        updateOperationMode()

        return true
    }
}

/// How one attempt at a piece of work ended, as far as the queues are concerned.
enum WorkOutcome<Backend: SyncBackend> {
    /// The work finished and leaves its queue. A fetch with more to come puts the next page first in line.
    case succeeded(SessionWork<Backend>.Result)

    /// The work failed and will be tried again after a wait. It stays where it is.
    case retryScheduled(Error)

    /// The wait is over. The work to retry takes the failed work's place with its retry count raised.
    case retrying(SessionWork<Backend>)

    /// These modify operations take the failed work's place, in order.
    case replaced([SessionModifyOperation<Backend>])

    /// Something that was set up is gone. The operation that sets it up again is queued unless one
    /// already is, and the failed work stays where it is with its retry count raised.
    case setupMissing(SessionSetupOperation<Backend>)
}
