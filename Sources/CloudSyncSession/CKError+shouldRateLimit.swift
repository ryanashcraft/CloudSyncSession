import CloudKit

extension CKError {
    var shouldRateLimit: Bool {
        if retryAfterSeconds != nil {
            return true
        }

        switch ckError.code {
        case .networkUnavailable,
             .networkFailure,
             .serviceUnavailable,
             .zoneBusy,
             .requestRateLimited,
             .serverResponseLost:
            return true
        case .partialFailure:
            guard let partialErrorsByRecordID = ckError.partialErrorsByItemID as? [CKRecord.ID: Error] else {
                return false
            }

            let partialErrors = partialErrorsByRecordID.compactMap { $0.value as? CKError }
            let allErrorsAreRetryable = partialErrors.allSatisfy(\.shouldThrottle)

            return allErrorsAreRetryable
        }
    }
}
