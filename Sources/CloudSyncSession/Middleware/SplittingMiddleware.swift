import os.log

struct SplittingMiddleware: Middleware {
    var session: CloudSyncSession

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        switch event {
        case .doWork(let work):
            switch work {
            case .modify(let operation):
                if operation.shouldSplit {
                    for splitOperation in operation.split {
                        session.dispatch(event: .doWork(.modify(splitOperation)))
                    }

                    return next(.noop)
                }
            default:
                break
            }
        default:
            break
        }

        return next(event)
    }
}
