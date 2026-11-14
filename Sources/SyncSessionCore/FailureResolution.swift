import Foundation

/// What the session should do about work that failed. A backend's library decides this for each
/// error its server can report and hands the session a function that returns it.
public enum FailureResolution<Backend: SyncBackend>: Sendable {
    /// Stop until the app starts the session again. The work keeps its place in the queue.
    case halt(Error)

    /// Try again after a wait. Carries the work to retry, which differs from the failed work when
    /// a fetch has to restart from a fresh change token. The interval is the wait the server asked
    /// for, if it asked for one.
    case retry(SessionWork<Backend>, Error, TimeInterval?)

    /// Send a modify again with these records and deletions, after resolving conflicts and
    /// leaving out what the server no longer has.
    case resend(records: [Backend.Record], recordIDsToDelete: [Backend.RecordID])

    /// The server rejected the request as too large; send it in smaller pieces.
    case split(Error)

    /// Something that was set up is gone. Set it up again, then try the work again.
    case redoSetup(Backend.SetupStep, Error)
}
