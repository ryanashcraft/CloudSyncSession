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
    var isPaused: Bool = false
    var hasHalted: Bool = false

    var operationMode: OperationMode = .modify

    var isRunning: Bool {
        (hasGoodAccountStatus ?? false) && (hasCreatedZone ?? false) && !hasHalted && !isPaused
    }

    var currentWork: SyncWork? {
        guard isRunning else {
            return nil
        }

        switch operationMode {
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
            case .modify(let operation):
                state.modifyQueue.append(operation)
            case .createZone(let operation):
                state.createZoneQueue.append(operation)
            }
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
        case .resolveConflict(let records, let recordIDsToDelete):
            let operation = ModifyOperation(records: records, recordIDsToDelete: recordIDsToDelete)

            if !state.modifyQueue.isEmpty {
                state.modifyQueue[0] = operation
            }
        case .halt:
            state.hasHalted = true
        case .retry:
            state.isPaused = true
        default:
            break
        }

        return state
    }
}
