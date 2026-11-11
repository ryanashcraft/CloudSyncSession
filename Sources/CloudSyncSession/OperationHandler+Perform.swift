extension OperationHandler {
    /// Hands one piece of work to the handler and waits for its result.
    func perform(_ work: SyncWork) async -> Result<SyncWork.Result, Error> {
        do {
            switch work {
            case let .fetch(operation):
                return .success(.fetch(try await handle(fetchOperation: operation)))
            case let .modify(operation):
                return .success(.modify(try await handle(modifyOperation: operation)))
            case let .createZone(operation):
                return .success(.createZone(try await handle(createZoneOperation: operation)))
            case let .createSubscription(operation):
                return .success(.createSubscription(try await handle(createSubscriptionOperation: operation)))
            }
        } catch {
            return .failure(error)
        }
    }
}
