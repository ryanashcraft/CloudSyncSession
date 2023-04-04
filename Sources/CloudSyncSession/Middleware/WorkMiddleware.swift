import Combine
import Foundation

private let workDelay = DispatchTimeInterval.milliseconds(60)

struct WorkMiddleware: Middleware {
    var session: CloudSyncSession

    private let dispatchQueue = DispatchQueue(label: "WorkMiddleware.Dispatch", qos: .userInitiated)

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        let prevState = session.state
        let event = next(event)
        let newState = session.state

        if let work = newState.currentWork {
            let prevWork = prevState.currentWork

            if prevWork?.id != work.id || prevWork?.retryCount != work.retryCount {
                dispatchQueue.asyncAfter(deadline: .now() + workDelay) {
                    self.doWork(work)
                }
            }
        }

        return event
    }

    private func doWork(_ work: SyncWork) {
        switch work {
        case let .fetch(operation):
            session.operationHandler.handle(fetchOperation: operation) { result in
                switch result {
                case let .failure(error):
                    session.dispatch(event: .workFailure(work, error))
                case let .success(response):
                    session.dispatch(event: .workSuccess(work, .fetch(response)))
                }
            }
        case let .modify(operation):
            session.operationHandler.handle(modifyOperation: operation) { result in
                switch result {
                case let .failure(error):
                    session.dispatch(event: .workFailure(work, error))
                case let .success(response):
                    session.dispatch(event: .workSuccess(work, .modify(response)))
                }
            }
        case let .createZone(operation):
            session.operationHandler.handle(createZoneOperation: operation) { result in
                switch result {
                case let .failure(error):
                    session.dispatch(event: .workFailure(work, error))
                case let .success(hasCreatedZone):
                    session.dispatch(event: .workSuccess(work, .createZone(hasCreatedZone)))
                }
            }
        case let .createSubscription(operation):
            session.operationHandler.handle(createSubscriptionOperation: operation) { result in
                switch result {
                case let .failure(error):
                    session.dispatch(event: .workFailure(work, error))
                case let .success(hasCreatedSubscription):
                    session.dispatch(event: .workSuccess(work, .createSubscription(hasCreatedSubscription)))
                }
            }
        }
    }
}
