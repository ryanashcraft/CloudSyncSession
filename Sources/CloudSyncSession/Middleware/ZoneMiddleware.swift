public struct ZoneMiddleware: Middleware {
    public var session: CloudSyncSession

    public init(session: CloudSyncSession) {
        self.session = session
    }

    public func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        switch event {
        case .start:
            if session.state.hasCreatedZone == nil {
                session.dispatch(event: .doWork(SyncWork.createZone(CreateZoneOperation(zoneID: session.zoneID))))
            }

            if session.state.hasCreatedSubscription == nil {
                session.dispatch(event: .doWork(SyncWork.createSubscription(CreateSubscriptionOperation(zoneID: session.zoneID))))
            }
        default:
            break
        }

        return next(event)
    }
}
