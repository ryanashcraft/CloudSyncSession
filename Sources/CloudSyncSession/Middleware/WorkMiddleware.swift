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
            case .pull(let operation):
                session.operationHandler.handle(fetchOperation: operation, dispatch: session.dispatch)
            case .push(let operation):
                session.operationHandler.handle(modifyOperation: operation, dispatch: session.dispatch)
            case .createZone(let operation):
                session.operationHandler.handle(createZoneOperation: operation, dispatch: session.dispatch)
            }
        }
    }
}
