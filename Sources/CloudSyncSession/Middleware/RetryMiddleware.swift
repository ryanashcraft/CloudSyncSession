import CloudKit
import Foundation
import os.log

private let maxRetryCount = 5

private func getRetryTimeInterval(retryCount: Int) -> TimeInterval {
    return TimeInterval(pow(Double(retryCount), 2.0))
}

struct RetryMiddleware: Middleware {
    var session: CloudSyncSession

    private let dispatchQueue = DispatchQueue(label: "ErrorMiddleware.Dispatch")

    private let log = OSLog(
        subsystem: "com.algebraiclabs.CloudSyncSession",
        category: "error middleware"
    )

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        switch event {
        case let .retry(work, error, suggestedInterval):
            let currentRetryCount = work.retryCount

            if currentRetryCount + 1 > maxRetryCount {
                session.dispatch(event: .workFailure(work, error))
            } else {
                let retryInterval: TimeInterval

                if let suggestedInterval = suggestedInterval {
                    retryInterval = suggestedInterval
                } else {
                    retryInterval = getRetryTimeInterval(retryCount: work.retryCount)
                }

                dispatchQueue.asyncAfter(deadline: .now() + retryInterval) {
                    session.dispatch(event: .retryWork(work))
                }
            }

            return next(event)
        default:
            return next(event)
        }
    }
}
