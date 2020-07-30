struct CallbackMiddleware: Middleware {
    var session: CloudSyncSession

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        switch event {
        case .workSuccess(let result):
            switch result {
            case .fetch(let response):
                session.onFetchCompleted?(response.changeToken, response.changedRecords, response.deletedRecordIDs)
            case .modify(let response):
                session.onRecordsModified?(response.savedRecords, response.deletedRecordIDs)
            default:
                break
            }
        default:
            break
        }

        return next(event)
    }
}
