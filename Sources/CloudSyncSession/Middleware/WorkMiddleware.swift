struct WorkMiddleware: Middleware {
    var session: CloudSyncSession

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        let prevState = session.state
        let event = next(event)
        let newState = session.state

        let isWorkEvent: Bool = {
            switch event {
            case .modify, .resolveConflict:
                return true
            default:
                return false
            }
        }()

        if isWorkEvent || (!prevState.isRunning && newState.isRunning) {
            work()
        }

        return event
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
                        session.logError(error)

                        if let event = session.mapErrorToEvent(error: error, work: work) {
                            session.dispatch(event: event)
                        }
                    }
                }
            }
        }
    }
}
