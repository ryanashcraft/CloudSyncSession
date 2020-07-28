import CloudKit

public enum SyncEvent {
    case start
    case accountStatusChanged(CKAccountStatus)
    case modify([CKRecord])
    case `continue`
    case halt
    case backoff
    case createZone
    case retry
    case splitThenRetry
    case conflict
    case partialFailure

    var logDescription: String {
        switch self {
        case .start:
            return "start"
        case .accountStatusChanged:
            return "account status changed"
        case .modify:
            return "modify"
        case .continue:
            return "continue"
        case .halt:
            return "halt"
        case .backoff:
            return "backoff"
        case .createZone:
            return "create zone"
        case .retry:
            return "retry"
        case .splitThenRetry:
            return "split then retry"
        case .conflict:
            return "conflict"
        case .partialFailure:
            return "partial failure"
        }
    }

    init?(error: Error) {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .notAuthenticated,
                 .managedAccountRestricted,
                 .quotaExceeded,
                 .badDatabase,
                 .incompatibleVersion,
                 .permissionFailure,
                 .missingEntitlement,
                 .badContainer,
                 .constraintViolation,
                 .referenceViolation,
                 .invalidArguments,
                 .serverRejectedRequest,
                 .resultsTruncated,
                 .changeTokenExpired:
                self = .halt
            case .internalError,
                 .networkUnavailable,
                 .networkFailure,
                 .serviceUnavailable,
                 .zoneBusy,
                 .requestRateLimited:
                self = .backoff
            case .serverResponseLost:
                self = .retry
            case .partialFailure, .batchRequestFailed:
                self = .partialFailure
            case .serverRecordChanged:
                self = .conflict
            case .limitExceeded:
                self = .splitThenRetry
            case .zoneNotFound, .userDeletedZone:
                self = .createZone
            case .assetNotAvailable,
                 .assetFileNotFound,
                 .assetFileModified,
                 .participantMayNeedVerification,
                 .alreadyShared,
                 .tooManyParticipants,
                 .unknownItem,
                 .operationCancelled:
                return nil
            @unknown default:
                return nil
            }
        } else {
            self = .halt
        }
    }
}
