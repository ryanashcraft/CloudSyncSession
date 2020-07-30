struct WorkMiddleware: Middleware {
    var session: CloudSyncSession

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        let prevState = session.state
        let event = next(event)
        let newState = session.state

        let isWorkEvent: Bool = {
            switch event {
            case .modify, .resolveConflict, .clearChangeToken, .fetch:
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
            case .fetch(let operation):
                session.operationHandler.handle(fetchOperation: operation) { result in
                    switch result {
                    case let .failure(error):
                        session.dispatch(event: .fetchFailure(error, operation))
                    case let .success(response):
                        session.dispatch(event: .fetchCompleted(response))
                    }
                }
            case .modify(let operation):
                session.operationHandler.handle(modifyOperation: operation) { result in
                    switch result {
                    case let .failure(error):
                        session.dispatch(event: .modifyFailure(error, operation))
                    case let .success(response):
                        session.dispatch(event: .modifyCompleted(response))
                    }
                }
            case .createZone(let operation):
                session.operationHandler.handle(createZoneOperation: operation) { result in
                    switch result {
                    case let .failure(error):
                        session.dispatch(event: .createZoneFailure(error, operation))
                    case let .success(hasCreatedZone):
                        session.dispatch(event: .zoneStatusChanged(hasCreatedZone))
                    }
                }
            }
        }
    }
}
