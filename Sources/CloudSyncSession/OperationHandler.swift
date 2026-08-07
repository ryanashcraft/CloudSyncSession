public protocol OperationHandler {
    func handle(fetchOperation: FetchOperation, completion: @escaping (Result<FetchOperation.Response, Error>) -> Void)
    func handle(modifyOperation: ModifyOperation, completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void)
    func handle(createZoneOperation: CreateZoneOperation, completion: @escaping (Result<Bool, Error>) -> Void)
    func handle(createSubscriptionOperation: CreateSubscriptionOperation, completion: @escaping (Result<Bool, Error>) -> Void)
    func leaveSharing(completion: @escaping (Result<Bool, Error>) -> Void)
}
