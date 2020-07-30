struct CallbackMiddleware: Middleware {
    var session: CloudSyncSession

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        switch event {
        case .modifyCompleted(let response):
            session.onRecordsModified?(response.savedRecords, response.deletedRecordIDs)
        case .fetchCompleted(let response):
            session.onFetchCompleted?(response.changeToken, response.changedRecords, response.deletedRecordIDs)
        default:
            break
        }

        return next(event)
    }
}
