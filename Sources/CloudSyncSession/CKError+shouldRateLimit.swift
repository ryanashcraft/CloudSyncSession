import CloudKit

extension CKError {
    var suggestedBackoffSeconds: TimeInterval? {
        if let retryAfterSeconds {
            return retryAfterSeconds
        }

        return partialErrorsByItemID?
            .values
            .compactMap { ($0 as? CKError)?.retryAfterSeconds }
            .max()
    }

    var indicatesShouldBackoff: Bool {
        if retryAfterSeconds != nil {
            return true
        }

        switch self.code {
        case .serviceUnavailable,
             .zoneBusy,
             .requestRateLimited:
            return true
        case .partialFailure:
            guard let partialErrorsByRecordID = self.partialErrorsByItemID as? [CKRecord.ID: Error] else {
                return false
            }

            let partialErrors = partialErrorsByRecordID.compactMap { $0.value as? CKError }
            let allErrorsAreRetryable = partialErrors.allSatisfy(\.indicatesShouldBackoff)

            return allErrorsAreRetryable
        default:
            return false
        }
    }
}
