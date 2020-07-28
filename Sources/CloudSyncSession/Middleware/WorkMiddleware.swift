struct WorkMiddleware: Middleware {
    var session: CloudSyncSession

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        switch event {
        case .modify:
            let newEvent = next(event)

            work()

            return newEvent
        default:
            return next(event)
        }
    }

    private func work() {
        if let work = session.state.currentWork {
            switch work {
            case .push(let operation):
                session.operationHandler.handle(modifyOperation: operation) { result in
                    switch result {
                    case .success(let records):
                        session.dispatch(event: .continue)
                        session.onRecordsModified?(records)
                    case .failure(let error):
                        if let event = SyncEvent(error: error) {
                            session.dispatch(event: event)
                        }
                    }
                }
            }
        }
    }
}
