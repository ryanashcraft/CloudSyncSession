/// Carries out the session's work against a server.
///
/// The session hands over one operation at a time and waits for its completion handler before it
/// does anything else. Each method must therefore call its completion handler exactly once, on any
/// thread. A handler that never calls it leaves the session waiting for good.
public protocol OperationHandler {
    func handle(fetchOperation: FetchOperation, completion: @escaping (Result<FetchOperation.Response, Error>) -> Void)
    func handle(modifyOperation: ModifyOperation, completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void)
    func handle(createZoneOperation: CreateZoneOperation, completion: @escaping (Result<Bool, Error>) -> Void)
    func handle(createSubscriptionOperation: CreateSubscriptionOperation, completion: @escaping (Result<Bool, Error>) -> Void)
}
