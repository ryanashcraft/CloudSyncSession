import CloudKit

/// The run loop: the one place that decides what the session does next.
///
/// It takes the work at the head of the queue, hands it to the operation handler, waits for the
/// result, updates the queue for that result, and only then looks at the queue again. Work that is
/// retried, resent after conflict resolution, or split is replaced where it stands, so it keeps its
/// place ahead of everything queued after it.
///
/// The loop is a task that exists only while there is work the session is allowed to do. It is
/// never interrupted while an operation is with the handler, so a second operation cannot be sent
/// alongside the first. `stop()` and `reset()` change the state and end whatever wait the loop is
/// in; the loop then acts on the state it finds, which is how it comes to send nothing more.
extension CloudSyncSession {
    /// Starts the run loop unless it is already running or there is nothing to do. Call with the lock held.
    func startRunLoopIfNeeded() {
        guard runLoopTask == nil, lockedState.currentWork != nil else {
            return
        }

        runLoopTask = Task(priority: .userInitiated) {
            await self.runLoop()
        }
    }

    private func runLoop() async {
        while let work = state.currentWork {
            // If the wait is cut short, or the queue changed during it, look at the queue afresh.
            guard await pause(.beforeWork, whileNextIs: work), state.currentWork?.id == work.id else {
                continue
            }

            switch await operationHandler.perform(work) {
            case let .success(result):
                complete(work, with: result)
            case let .failure(error):
                await recover(work, from: error)
            }
        }

        runLoopEnded()
    }

    /// Lets go of the finished loop, and starts another if work arrived between the loop's last
    /// look at the queue and now.
    private func runLoopEnded() {
        lock.lock()
        defer { lock.unlock() }

        runLoopTask = nil
        startRunLoopIfNeeded()
    }

    // MARK: Waiting

    /// Waits, as long as `work` is what the session should do next. Returns false without waiting
    /// if it is not, and false as soon as `stop()` or `reset()` cuts the wait short.
    private func pause(_ pause: Pause, whileNextIs work: SyncWork) async -> Bool {
        guard let waiting = beginPause(pause, whileNextIs: work) else {
            return false
        }

        let result = await waiting.result

        endPause()

        switch result {
        case .success:
            return true
        case .failure:
            return false
        }
    }

    /// Starts the wait under the lock, so that a `stop()` or `reset()` either comes first and is
    /// seen here, or comes after and finds the wait to cancel.
    private func beginPause(_ pause: Pause, whileNextIs work: SyncWork) -> Task<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }

        guard lockedState.currentWork?.id == work.id else {
            return nil
        }

        let waiting = Task(priority: .userInitiated) { [pacing] in
            try await pacing.pause(pause)
        }

        currentPause = waiting

        return waiting
    }

    private func endPause() {
        lock.lock()
        defer { lock.unlock() }

        currentPause = nil
    }

    // MARK: Results

    private func complete(_ work: SyncWork, with result: SyncWork.Result) {
        update { change in
            // Reported even if the session was stopped while the operation was under way: the
            // server has the change, and the app needs to know. After a reset the work is no longer
            // queued and its result is dropped.
            guard change.state.contains(work) else {
                return
            }

            change.emit(.workSuccess(work, result))
            change.state.apply(.succeeded(result), to: work)
        }
    }

    private func recover(_ work: SyncWork, from error: Error) async {
        // Skip the app's conflict resolver when its answer would not be used.
        guard shouldAct(onFailureOf: work, in: state) else {
            return
        }

        // Runs the app's conflict resolver, so it happens before taking the lock.
        let resolution = failureResolver.resolution(for: error, work: work)

        let retry: (work: SyncWork, delay: TimeInterval)? = update { change in
            guard shouldAct(onFailureOf: work, in: change.state) else {
                return nil
            }

            change.emit(.workFailure(work, error))

            return apply(resolution, to: work, in: &change)
        }

        guard let retry, await pause(.retryBackoff(retry.delay), whileNextIs: work) else {
            return
        }

        update { change in
            guard shouldAct(onFailureOf: work, in: change.state) else {
                return
            }

            change.emit(.retryWork(retry.work))
            change.state.apply(.retrying(retry.work), to: work)
        }
    }

    /// Whether to act on a failure of this work. Not while the session is halted: the work stays
    /// queued and is sent again when the session next starts. And not once the work has left the
    /// queue, which is what `reset()` does to it.
    private func shouldAct(onFailureOf work: SyncWork, in state: SyncState) -> Bool {
        !state.isHalted && state.contains(work)
    }

    /// Updates the queue for how the failure is to be handled. Returns the work to retry and how
    /// long to wait first when the answer is to retry.
    private func apply(
        _ resolution: FailureResolution,
        to work: SyncWork,
        in change: inout Change
    ) -> (work: SyncWork, delay: TimeInterval)? {
        func halt(_ error: Error) {
            change.emit(.halt(error))
            change.state.isHalted = true
        }

        switch resolution {
        case let .halt(error):
            halt(error)
        case let .retry(workToRetry, error, suggestedInterval):
            change.emit(.retry(workToRetry, error, suggestedInterval))
            change.state.apply(.retryScheduled(error), to: work)

            switch RetryPolicy.decision(retryCount: workToRetry.retryCount, suggestedInterval: suggestedInterval) {
            case let .wait(delay):
                return (workToRetry, delay)
            case .giveUp:
                halt(error)
            }
        case let .resend(records, recordIDsToDelete):
            guard case let .modify(failedOperation) = work else {
                halt(CKError(.internalError))

                break
            }

            let operation = ModifyOperation(
                records: records,
                recordIDsToDelete: recordIDsToDelete,
                checkpointID: failedOperation.checkpointID,
                userInfo: failedOperation.userInfo
            )

            change.emit(.resolveConflict(work, records, recordIDsToDelete))
            change.state.apply(.replaced([operation]), to: work)
        case let .split(error):
            // Only a modify can be made smaller, and only if it holds more than one item.
            guard case let .modify(failedOperation) = work, let halves = failedOperation.splitInHalf else {
                halt(error)

                break
            }

            change.emit(.split(work, error))
            change.state.apply(.replaced(halves), to: work)
        case let .recreateZone(error):
            // Counts against the work's retries, so a zone that keeps disappearing ends in a halt.
            guard RetryPolicy.decision(retryCount: work.retryCount, suggestedInterval: nil) != .giveUp else {
                halt(error)

                break
            }

            let createZoneOperation = CreateZoneOperation(zoneID: zoneID)

            if change.state.createZoneQueue.isEmpty {
                change.emit(.doWork(.createZone(createZoneOperation)))
            }

            change.emit(.retryWork(work))
            change.state.apply(.zoneMissing(createZoneOperation), to: work)
        }

        return nil
    }
}
