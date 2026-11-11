import Foundation

/// One piece of work in a session's queues.
public enum SessionWork<Backend: SyncBackend>: Identifiable {
    public enum Result {
        case modify(SessionModifyOperation<Backend>.Response)
        case fetch(SessionFetchOperation<Backend>.Response)

        /// Whether the step is now in place.
        case setup(Bool)
    }

    case modify(SessionModifyOperation<Backend>)
    case fetch(SessionFetchOperation<Backend>)
    case setup(SessionSetupOperation<Backend>)

    public var id: UUID {
        switch self {
        case let .modify(operation):
            return operation.id
        case let .fetch(operation):
            return operation.id
        case let .setup(operation):
            return operation.id
        }
    }

    /// How many times this work has been retried.
    public var retryCount: Int {
        switch self {
        case let .modify(operation):
            return operation.retryCount
        case let .fetch(operation):
            return operation.retryCount
        case let .setup(operation):
            return operation.retryCount
        }
    }

    var retried: SessionWork {
        switch self {
        case var .modify(operation):
            operation.retryCount += 1

            return .modify(operation)
        case var .fetch(operation):
            operation.retryCount += 1

            return .fetch(operation)
        case var .setup(operation):
            operation.retryCount += 1

            return .setup(operation)
        }
    }

    var debugDescription: String {
        switch self {
        case let .modify(operation):
            return "Modify with \(operation.records.count) records to save and \(operation.recordIDsToDelete.count) to delete"
        case .fetch:
            return "Fetch"
        case let .setup(operation):
            return "Set up \(Backend.describe(operation.step))"
        }
    }
}

public struct SessionFetchOperation<Backend: SyncBackend>: Identifiable {
    public struct Response {
        public let changeToken: Backend.ChangeToken?
        public let changedRecords: [Backend.Record]
        public let deletedRecordIDs: [Backend.RecordID]
        public let hasMore: Bool

        public init(
            changeToken: Backend.ChangeToken?,
            changedRecords: [Backend.Record],
            deletedRecordIDs: [Backend.RecordID],
            hasMore: Bool
        ) {
            self.changeToken = changeToken
            self.changedRecords = changedRecords
            self.deletedRecordIDs = deletedRecordIDs
            self.hasMore = hasMore
        }
    }

    public let id = UUID()

    /// The point in the server's history to fetch from. The session replaces it when the server
    /// reports that it has expired, which is why it is not a constant.
    public var changeToken: Backend.ChangeToken?

    public internal(set) var retryCount: Int = 0

    public init(changeToken: Backend.ChangeToken?) {
        self.changeToken = changeToken
    }
}

public struct SessionModifyOperation<Backend: SyncBackend>: Identifiable {
    public struct Response {
        public let savedRecords: [Backend.Record]
        public let deletedRecordIDs: [Backend.RecordID]

        public init(savedRecords: [Backend.Record], deletedRecordIDs: [Backend.RecordID]) {
            self.savedRecords = savedRecords
            self.deletedRecordIDs = deletedRecordIDs
        }
    }

    public let id = UUID()
    public let checkpointID: UUID?
    public let userInfo: [String: Any]?

    public internal(set) var records: [Backend.Record]
    public internal(set) var recordIDsToDelete: [Backend.RecordID]
    public internal(set) var retryCount: Int = 0

    public init(records: [Backend.Record], recordIDsToDelete: [Backend.RecordID], checkpointID: UUID?, userInfo: [String: Any]?) {
        self.records = records
        self.recordIDsToDelete = recordIDsToDelete
        self.checkpointID = checkpointID
        self.userInfo = userInfo
    }

    var shouldSplit: Bool {
        return records.count + recordIDsToDelete.count > Backend.maxItemsPerModify
    }

    var split: [SessionModifyOperation] {
        let splitRecords: [[Backend.Record]] = records.chunked(into: Backend.maxItemsPerModify)
        let splitRecordIDsToDelete: [[Backend.RecordID]] = recordIDsToDelete.chunked(into: Backend.maxItemsPerModify)

        let recordChunks = splitRecords.map {
            SessionModifyOperation(records: $0, recordIDsToDelete: [], checkpointID: nil, userInfo: userInfo)
        }
        let deletionChunks = splitRecordIDsToDelete.map {
            SessionModifyOperation(records: [], recordIDsToDelete: $0, checkpointID: nil, userInfo: userInfo)
        }

        var chunks = recordChunks + deletionChunks

        // The checkpoint must ride the final chunk so checkpoint-correlated
        // waiters resolve only after every piece of the original operation
        // has completed.
        if let lastChunk = chunks.last {
            chunks[chunks.count - 1] = SessionModifyOperation(
                records: lastChunk.records,
                recordIDsToDelete: lastChunk.recordIDsToDelete,
                checkpointID: checkpointID,
                userInfo: userInfo
            )
        }

        return chunks
    }

    /// The two pieces to send instead after the server rejects this operation as too large, or nil
    /// when it holds a single item and cannot be made any smaller.
    var splitInHalf: [SessionModifyOperation]? {
        guard records.count + recordIDsToDelete.count > 1 else {
            return nil
        }

        guard records.count > 1 || recordIDsToDelete.count > 1 else {
            // One save and one deletion. Halving each list on its own would produce an empty
            // piece and this same operation again.
            return [
                SessionModifyOperation(records: records, recordIDsToDelete: [], checkpointID: nil, userInfo: userInfo),
                SessionModifyOperation(records: [], recordIDsToDelete: recordIDsToDelete, checkpointID: checkpointID, userInfo: userInfo),
            ]
        }

        let firstHalfRecords = Array(records[0 ..< records.count / 2])
        let secondHalfRecords = Array(records[records.count / 2 ..< records.count])

        let firstHalfRecordIDsToDelete = Array(recordIDsToDelete[0 ..< recordIDsToDelete.count / 2])
        let secondHalfRecordIDsToDelete = Array(recordIDsToDelete[recordIDsToDelete.count / 2 ..< recordIDsToDelete.count])

        return [
            SessionModifyOperation(records: firstHalfRecords, recordIDsToDelete: firstHalfRecordIDsToDelete, checkpointID: nil, userInfo: userInfo),
            SessionModifyOperation(records: secondHalfRecords, recordIDsToDelete: secondHalfRecordIDsToDelete, checkpointID: checkpointID, userInfo: userInfo),
        ]
    }
}

/// Work that puts one of the backend's setup steps in place.
public struct SessionSetupOperation<Backend: SyncBackend>: Identifiable {
    public let id = UUID()
    public let step: Backend.SetupStep

    public internal(set) var retryCount: Int = 0

    public init(step: Backend.SetupStep) {
        self.step = step
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
