import CloudKit

/// The run loop: the one place that decides what the session does next.
///
/// It takes the work at the head of the queue, hands it to the operation handler, waits for the
/// result, updates the queue for that result, and only then looks at the queue again. Work that is
/// retried, resent after conflict resolution, or split is replaced where it stands, so it keeps its
/// place ahead of everything queued after it.
///
/// The loop is a task that exists only while there is work the session is allowed to do. It waits
/// on one thing at a time: a pause of its own, or an operation that is with the handler. `stop()`
/// and `reset()` change the state and cancel that one thing. The loop is not itself cancelled: it
/// waits for the cancelled operation to wind down, so a second operation cannot be sent alongside
/// it, and then acts on the state it finds, which is how it comes to send nothing more.
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
            // If the wait is cut short, the queue changed during it, or the operation was
            // cancelled, look at the queue afresh.
            guard await pause(.beforeWork, whileNextIs: work), let result = await send(work) else {
                continue
            }

            switch result {
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
        let waiting: Task<Void, Error>? = beginStep(whileNextIs: work) { [pacing] in
            Task(priority: .userInitiated) {
                try await pacing.pause(pause)
            }
        }

        guard let waiting else {
            return false
        }

        let result = await waiting.result

        endStep()

        switch result {
        case .success:
            return true
        case .failure:
            return false
        }
    }

    // MARK: Sending

    /// Hands the work to the operation handler, as long as it is what the session should do next,
    /// and waits for the result. Returns nil if the work was not sent, or if `stop()` or `reset()`
    /// cancelled the operation and it did not succeed regardless.
    private func send(_ work: SyncWork) async -> Result<SyncWork.Result, Error>? {
        let handedOver = Unchecked(value: work)

        let operation: Task<Unchecked<Result<SyncWork.Result, Error>>, Never>? = beginStep(whileNextIs: work) {
            Task(priority: .userInitiated) {
                Unchecked(value: await self.operationHandler.perform(handedOver.value))
            }
        }

        guard let operation else {
            return nil
        }

        let result = await operation.value.value

        endStep()

        // Whatever a cancelled operation reports in place of a result says nothing about the
        // work, which stays queued. A cancelled operation that succeeded anyway did the work.
        if operation.isCancelled, case .failure = result {
            return nil
        }

        return result
    }

    // MARK: Steps

    /// Starts something for the loop to wait on and makes it the thing `stop()` and `reset()`
    /// cancel. This happens under the lock, so that a `stop()` or `reset()` either comes first and
    /// is seen here, in which case nothing is started, or comes after and finds the step to cancel.
    private func beginStep<Success, Failure>(
        whileNextIs work: SyncWork,
        _ start: () -> Task<Success, Failure>
    ) -> Task<Success, Failure>? {
        lock.lock()
        defer { lock.unlock() }

        guard lockedState.currentWork?.id == work.id else {
            return nil
        }

        let step = start()

        cancelCurrentStep = { step.cancel() }

        return step
    }

    private func endStep() {
        lock.lock()
        defer { lock.unlock() }

        cancelCurrentStep = nil
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

/// Carries a value between the run loop and the task of the one operation it is waiting on. Only
/// one of the two touches the value at a time: the loop hands the work over and does not look at
/// it again until the operation's task has finished and handed back the result.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}
