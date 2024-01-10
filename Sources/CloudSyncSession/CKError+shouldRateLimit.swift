import CloudKit

extension CKError {
    var shouldRateLimit: Bool {
        if retryAfterSeconds != nil {
            return true
        }

        switch self.code {
        case .networkUnavailable,
             .networkFailure,
             .serviceUnavailable,
             .zoneBusy,
             .requestRateLimited,
             .serverResponseLost:
            return true
        case .partialFailure:
            guard let partialErrorsByRecordID = self.partialErrorsByItemID as? [CKRecord.ID: Error] else {
                return false
            }

            let partialErrors = partialErrorsByRecordID.compactMap { $0.value as? CKError }
            let allErrorsAreRetryable = partialErrors.allSatisfy(\.shouldRateLimit)

            return allErrorsAreRetryable
        default:
            return false
        }
    }
}
