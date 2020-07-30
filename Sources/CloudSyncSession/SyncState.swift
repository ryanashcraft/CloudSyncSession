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

        if !eligibleOperationModes.contains(operationMode) {
            operationMode = eligibleOperationModes.first ?? nil
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
        case .doWork(let work):
            switch work {
            case .fetch(let operation):
                state.fetchQueue.append(operation)

                if state.currentWork == nil {
                    state.operationMode = .fetch
                }
            case .modify(let operation):
                state.modifyQueue.append(operation)

                if state.currentWork == nil {
                    state.operationMode = .modify
                }
            case .createZone(let operation):
                state.createZoneQueue.append(operation)

                if state.currentWork == nil {
                    state.operationMode = .createZone
                }
            }

            state.updateOperationMode()
        case let .workFailure(_, work):
            switch work {
            case .fetch:
                if !state.fetchQueue.isEmpty {
                    state.fetchQueue.removeFirst()
                }
            case .modify:
                if !state.modifyQueue.isEmpty {
                    state.modifyQueue.removeFirst()
                }
            case .createZone:
                state.hasCreatedZone = false
            }

            state.updateOperationMode()
        case .workSuccess(let result):
            switch result {
            case .fetch(let response):
                if !state.fetchQueue.isEmpty {
                    state.fetchQueue.removeFirst()
                }

                if response.hasMore {
                    state.fetchQueue = [FetchOperation(changeToken: response.changeToken)] + state.fetchQueue
                }
            case .modify(_):
                if !state.modifyQueue.isEmpty {
                    state.modifyQueue.removeFirst()
                }
            case .createZone(let didCreateZone):
                state.hasCreatedZone = didCreateZone
            }

            state.updateOperationMode()
        case .resolveConflict(let records, let recordIDsToDelete):
            let operation = ModifyOperation(records: records, recordIDsToDelete: recordIDsToDelete)

            if !state.modifyQueue.isEmpty {
                state.modifyQueue[0] = operation
            }
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
