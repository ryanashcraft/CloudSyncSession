import SyncSessionCore

/// Carries out the session's work against a server.
///
/// The session hands over one operation at a time and waits for the method to return before it
/// does anything else. A method that never returns leaves the session waiting for good.
///
/// When the session is stopped or reset it cancels the task the method is running in. A handler
/// should then give up an operation it has not sent yet, and return or throw without delay. It
/// must not return while an operation it has sent could still reach the server, because
/// `stopAndWait()` promises its caller that nothing is under way once it returns; if the request
/// cannot be recalled, that means waiting for it and returning its real result. What a cancelled
/// method throws does not matter; the session does not treat it as a failure of the work.
public protocol OperationHandler {
    func handle(fetchOperation: FetchOperation) async throws -> FetchOperation.Response
    func handle(modifyOperation: ModifyOperation) async throws -> ModifyOperation.Response
    func handle(createZoneOperation: CreateZoneOperation) async throws -> Bool
    func handle(createSubscriptionOperation: CreateSubscriptionOperation) async throws -> Bool
}
