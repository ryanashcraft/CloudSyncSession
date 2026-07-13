import CloudKit
import Foundation

public extension CloudSyncSession {
    /// An async counterpart to ``eventsPublisher``.
    ///
    /// Lossless from stream creation, never replays. Like eventsPublisher, an
    /// event is observed once per middleware recursion level, so a single
    /// dispatched event appears several times, including transformed variants.
    /// Match on what you need rather than counting elements.
    var events: AsyncStream<SyncEvent> {
        eventsBroadcast.makeStream()
    }

    /// An async counterpart to ``fetchWorkCompletedSubject``.
    ///
    /// Lossless from stream creation: create the stream before dispatching
    /// work and it observes every completion that follows. Elements buffer
    /// until iterated, so consume promptly.
    var fetchWorkCompletions: AsyncStream<(FetchOperation, FetchOperation.Response)> {
        fetchWorkCompletionsBroadcast.makeStream()
    }

    /// An async counterpart to ``modifyWorkCompletedSubject``.
    ///
    /// Lossless from stream creation, same contract as ``fetchWorkCompletions``.
    var modifyWorkCompletions: AsyncStream<(ModifyOperation, ModifyOperation.Response)> {
        modifyWorkCompletionsBroadcast.makeStream()
    }

    /// An async counterpart to ``haltedSubject``.
    ///
    /// State surface: the first element is the current value (nil when the
    /// session is not halted), followed by changes, buffering only the newest.
    var haltedErrors: AsyncStream<Error?> {
        haltedErrorsBroadcast.makeStream()
    }

    /// An async counterpart to ``accountStatusSubject``.
    ///
    /// State surface: replays the latest known status, then changes.
    var accountStatuses: AsyncStream<CKAccountStatus?> {
        accountStatusesBroadcast.makeStream()
    }

    /// An async counterpart to the published ``state``.
    ///
    /// State surface: the first element is the current state, followed by
    /// every state change, buffering only the newest.
    var states: AsyncStream<SyncState> {
        statesBroadcast.makeStream()
    }
}
