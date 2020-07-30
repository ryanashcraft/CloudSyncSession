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
        case let .retry(error, work):
            let currentRetryCount = work.retryCount

            if currentRetryCount + 1 > maxRetryCount {
                session.dispatch(event: .workFailure(error, work))
            } else {
                dispatchQueue.asyncAfter(deadline: .now() + getRetryTimeInterval(retryCount: work.retryCount)) {
                    session.dispatch(event: event)
                }
            }

            return next(event)
        default:
            return next(event)
        }
    }
}
