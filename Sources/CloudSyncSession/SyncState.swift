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
        case .zoneStatusChanged(let hasCreatedZone):
            state.hasCreatedZone = hasCreatedZone
        case .createZoneCompleted:
            state.hasCreatedZone = true
        case .modify(let records, let recordIDsToDelete):
            let operation = ModifyOperation(records: records, recordIDsToDelete: recordIDsToDelete)

            state.modifyQueue.append(operation)
        case .resolveConflict(let records, let recordIDsToDelete):
            let operation = ModifyOperation(records: records, recordIDsToDelete: recordIDsToDelete)

            if !state.modifyQueue.isEmpty {
                state.modifyQueue[0] = operation
            }
        case .modifyCompleted:
            if !state.modifyQueue.isEmpty {
                state.modifyQueue.removeFirst()
            }
        case let .fetchCompleted(response):
            if !state.fetchQueue.isEmpty {
                state.fetchQueue.removeFirst()
            }

            if response.hasMore {
                state.fetchQueue = [FetchOperation(changeToken: response.changeToken)] + state.fetchQueue
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
