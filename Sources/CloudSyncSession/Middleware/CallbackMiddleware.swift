struct CallbackMiddleware: Middleware {
    var session: CloudSyncSession

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        switch event {
        case .modifyCompleted(let records, let deletedIDs):
            session.onRecordsModified?(records)
        case .fetchCompleted(let records, let deletedIDs):
            session.onRecordsModified?(records)
            session.onChangeTokenChanged?(session.state.changeToken)
        default:
            break
        }

        return next(event)
    }
}
