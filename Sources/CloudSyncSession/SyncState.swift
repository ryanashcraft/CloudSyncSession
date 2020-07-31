struct SyncState {
    enum OperationMode {
        case modify
        case fetch
        case createZone
    }

    var modifyQueue = [ModifyOperation]()
    var fetchQueue = [FetchOperation]()
    var createZoneQueue = [CreateZoneOperation]()
    var hasGoodAccountStatus: Bool? = nil
    var hasCreatedZone: Bool? = nil
    var hasHalted: Bool = false

    var operationMode: OperationMode?

    var isRunning: Bool {
        (hasGoodAccountStatus ?? false) && (hasCreatedZone ?? false) && !hasHalted
    }

    var currentWork: SyncWork? {
        guard isRunning else {
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
        }

        return nil
    }

    mutating func updateOperationMode() {
        let eligibleOperationModes: [OperationMode?] = [.createZone, .modify, .fetch, nil].filter { mode in
            switch mode {
            case .createZone:
                return !createZoneQueue.isEmpty
            case .fetch:
                return !fetchQueue.isEmpty
            case .modify:
                return !modifyQueue.isEmpty
            case nil:
                return true
            }
        }

        if operationMode == nil || !eligibleOperationModes.contains(operationMode) {
            operationMode = eligibleOperationModes.first ?? nil
        }
    }

    mutating func pushWork(_ work: SyncWork) {
        switch work {
        case .fetch(let operation):
            fetchQueue.append(operation)
        case .modify(let operation):
            modifyQueue.append(operation)
        case .createZone(let operation):
            createZoneQueue.append(operation)
        }
    }

    mutating func popWork(work: SyncWork) {
        switch work {
        case let .fetch(operation):
            fetchQueue = fetchQueue.filter { $0 != operation }
        case let .modify(operation):
            modifyQueue = modifyQueue.filter { $0 != operation }
        case let .createZone(operation):
            createZoneQueue = createZoneQueue.filter { $0 != operation }
        }
    }

    func reduce(event: SyncEvent) -> SyncState {
        var state = self

        switch event {
        case .accountStatusChanged(let accountStatus):
            switch accountStatus {
            case .available:
                state.hasGoodAccountStatus = true
            default:
                state.hasGoodAccountStatus = false
            }
        case .retryWork(let work):
            state.popWork(work: work)
            state.pushWork(work.retried)

            fallthrough
        case .doWork(let work):
            state.pushWork(work)
            state.updateOperationMode()
        case .workFailure(let work, _):
            state.popWork(work: work)
            state.updateOperationMode()
        case .workSuccess(let work, let result):
            state.popWork(work: work)

            switch result {
            case .fetch(let response):
                if response.hasMore {
                    state.fetchQueue = [FetchOperation(changeToken: response.changeToken)] + state.fetchQueue
                }
            case .createZone(let didCreateZone):
                state.hasCreatedZone = didCreateZone
            default:
                break
            }

            state.updateOperationMode()
        case let .resolveConflict(work, records, recordIDsToDelete):
            let operation = ModifyOperation(records: records, recordIDsToDelete: recordIDsToDelete)

            state.popWork(work: work)
            state.pushWork(.modify(operation))
        case .halt:
            state.hasHalted = true
        case .start,
             .handleConflict,
             .retry,
             .splitThenRetry:
            break
        }

        return state
    }
}
