//
// Copyright (c) 2020 Jay Hickey
// Copyright (c) 2020-present Ryan Ashcraft
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//

import CloudKit
import Foundation
import os.log

struct ErrorMiddleware: Middleware {
    var session: CloudSyncSession

    private let log = OSLog(
        subsystem: "com.ryanashcraft.CloudSyncSession",
        category: "Error Middleware"
    )

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        switch event {
        case let .workFailure(work, error):
            if let event = mapErrorToEvent(error: error, work: work, zoneID: session.zoneID) {
                return next(event)
            }

            return next(event)
        default:
            return next(event)
        }
    }

    func mapErrorToEvent(error: Error, work: SyncWork, zoneID: CKRecordZone.ID) -> SyncEvent? {
        if let ckError = error as? CKError {
            os_log(
                "Handling CloudKit error (code %{public}d): %{public}@",
                log: log,
                type: .error,
                ckError.errorCode,
                ckError.localizedDescription
            )

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
                 .batchRequestFailed,
                 .internalError:
                return .halt(error)
            case .networkUnavailable,
                 .networkFailure,
                 .serviceUnavailable,
                 .zoneBusy,
                 .requestRateLimited,
                 .serverResponseLost:
                var suggestedInterval: TimeInterval?

                if let retryAfter = ckError.userInfo[CKErrorRetryAfterKey] as? NSNumber {
                    suggestedInterval = TimeInterval(retryAfter.doubleValue)
                }

                return .retry(work, error, suggestedInterval)
            case .changeTokenExpired:
                var suggestedInterval: TimeInterval?

                if let retryAfter = ckError.userInfo[CKErrorRetryAfterKey] as? NSNumber {
                    suggestedInterval = TimeInterval(retryAfter.doubleValue)
                }

                switch work {
                case var .fetch(modifiedOperation):
                    modifiedOperation.changeToken = resolveExpiredChangeToken()

                    return .retry(.fetch(modifiedOperation), error, suggestedInterval)
                default:
                    return .halt(error)
                }
            case .partialFailure:
                switch work {
                case .fetch:
                    // Supported fetch partial failures: changeTokenExpired

                    guard let partialErrors = ckError.partialErrorsByItemID else {
                        return .halt(error)
                    }

                    guard let error = partialErrors.first?.value as? CKError, partialErrors.count == 1 else {
                        return .halt(error)
                    }

                    return mapErrorToEvent(error: error, work: work, zoneID: zoneID)
                case let .modify(operation):
                    // Supported modify partial failures: batchRequestFailed and serverRecordChanged

                    guard let partialErrors = ckError.partialErrorsByItemID as? [CKRecord.ID: Error] else {
                        return .halt(error)
                    }

                    let recordIDsNotSavedOrDeleted = Set(partialErrors.keys)

                    let unhandleableErrorsByItemID = partialErrors
                        .filter { _, error in
                            guard let error = error as? CKError else {
                                return true
                            }

                            switch error.code {
                            case .batchRequestFailed, .serverRecordChanged, .unknownItem:
                                return false
                            default:
                                return true
                            }
                        }

                    if !unhandleableErrorsByItemID.isEmpty {
                        // Abort due to unknown error
                        return .halt(error)
                    }

                    // All IDs for records that are unknown by the container (probably deleted by another client)
                    let unknownItemRecordIDs = Set(
                        partialErrors
                            .filter { _, error in
                                if let error = error as? CKError, error.code == .unknownItem {
                                    return true
                                }

                                return false
                            }
                            .keys
                    )

                    // All IDs for records that failed to be modified due to some other error in the batch modify operation
                    let batchRequestFailedRecordIDs = Set(
                        partialErrors
                            .filter { _, error in
                                if let error = error as? CKError, error.code == .batchRequestFailed {
                                    return true
                                }

                                return false
                            }
                            .keys
                    )

                    // All errors for records that failed because there was a conflict
                    let serverRecordChangedErrors = partialErrors
                        .filter { _, error in
                            if let error = error as? CKError, error.code == .serverRecordChanged {
                                return true
                            }

                            return false
                        }
                        .values

                    // Resolved records
                    let resolvedConflictsToSave = serverRecordChangedErrors
                        .compactMap { error in
                            self.resolveConflict(error: error)
                        }

                    if resolvedConflictsToSave.count != serverRecordChangedErrors.count {
                        // Abort if couldn't handle conflict for some reason
                        os_log(
                            "Aborting since count of resolved records not equal to number of server record changed errors",
                            log: log,
                            type: .error
                        )

                        return .halt(error)
                    }

                    let recordsToSaveWithoutUnknowns = operation.records
                        .filter { recordIDsNotSavedOrDeleted.contains($0.recordID) }
                        .filter { !unknownItemRecordIDs.contains($0.recordID) }

                    let recordIDsToDeleteWithoutUnknowns = operation
                        .recordIDsToDelete
                        .filter(recordIDsNotSavedOrDeleted.contains)
                        .filter { !unknownItemRecordIDs.contains($0) }

                    let conflictsToSaveSet = Set(resolvedConflictsToSave.map(\.recordID))

                    let batchRequestFailureRecordsToSave = recordsToSaveWithoutUnknowns
                        .filter {
                            !conflictsToSaveSet.contains($0.recordID) && batchRequestFailedRecordIDs.contains($0.recordID)
                        }

                    let allResolvedRecordsToSave = batchRequestFailureRecordsToSave + resolvedConflictsToSave

                    return .resolveConflict(work, allResolvedRecordsToSave, recordIDsToDeleteWithoutUnknowns)
                default:
                    return .halt(error)
                }
            case .serverRecordChanged:
                guard let resolvedConflictToSave = resolveConflict(error: error) else {
                    // If couldn't handle conflict for the records, abort
                    return .halt(error)
                }

                return .resolveConflict(work, [resolvedConflictToSave], [])
            case .limitExceeded:
                return .split(work, error)
            case .zoneNotFound, .userDeletedZone:
                return .doWork(.createZone(CreateZoneOperation(zoneID: zoneID)))
            case .assetNotAvailable,
                 .assetFileNotFound,
                 .assetFileModified,
                 .participantMayNeedVerification,
                 .alreadyShared,
                 .tooManyParticipants,
                 .unknownItem,
                 .operationCancelled,
                 .accountTemporarilyUnavailable:
                return .halt(error)
            @unknown default:
                return nil
            }
        } else {
            return .halt(error)
        }
    }

    func resolveConflict(error: Error) -> CKRecord? {
        guard let effectiveError = error as? CKError else {
            os_log(
                "resolveConflict called on an error that was not a CKError. The error was %{public}@",
                log: log,
                type: .fault,
                String(describing: self)
            )

            return nil
        }

        guard effectiveError.code == .serverRecordChanged else {
            os_log(
                "resolveConflict called on a CKError that was not a serverRecordChanged error. The error was %{public}@",
                log: log,
                type: .fault,
                String(describing: effectiveError)
            )

            return nil
        }

        guard let clientRecord = effectiveError.clientRecord else {
            os_log(
                "Failed to obtain client record from serverRecordChanged error. The error was %{public}@",
                log: log,
                type: .fault,
                String(describing: effectiveError)
            )

            return nil
        }

        guard let serverRecord = effectiveError.serverRecord else {
            os_log(
                "Failed to obtain server record from serverRecordChanged error. The error was %{public}@",
                log: log,
                type: .fault,
                String(describing: effectiveError)
            )

            return nil
        }

        os_log(
            "CloudKit conflict with record of type %{public}@. Running conflict resolver", log: log,
            type: .error, serverRecord.recordType
        )

        guard let resolveConflict = session.resolveConflict else {
            return nil
        }

        guard let resolvedRecord = resolveConflict(clientRecord, serverRecord) else {
            return nil
        }

        // Always return the server record so we don't end up in a conflict loop.
        // The server record has the change tag we want to use.
        // https://developer.apple.com/documentation/cloudkit/ckerror/2325208-serverrecordchanged

        // First, nil out all keys in case any keys in the newly resolved record are nil,
        // we don't want those to carry over into the final resolved copy
        serverRecord.removeAllFields()

        // Copy over all fields from the resolved record
        serverRecord.copyFields(from: resolvedRecord)

        return serverRecord
    }

    func resolveExpiredChangeToken() -> CKServerChangeToken? {
        guard let resolveExpiredChangeToken = session.resolveExpiredChangeToken else {
            return nil
        }

        return resolveExpiredChangeToken()
    }
}

internal extension CKRecord {
    func removeAllFields() {
        let encryptedKeys = Set(encryptedValues.allKeys())

        allKeys().forEach { key in
            if encryptedKeys.contains(key) {
                encryptedValues[key] = nil
            } else {
                self[key] = nil
            }
        }
    }

    func copyFields(from otherRecord: CKRecord) {
        let encryptedKeys = Set(otherRecord.encryptedValues.allKeys())

        otherRecord.allKeys().forEach { key in
            if encryptedKeys.contains(key) {
                encryptedValues[key] = otherRecord.encryptedValues[key]
            } else {
                self[key] = otherRecord[key]
            }
        }
    }
}
