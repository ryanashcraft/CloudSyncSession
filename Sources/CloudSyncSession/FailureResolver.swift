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
import SyncSessionCore

/// Decides what to do about a failure reported by CloudKit. It changes nothing in the session. Its only side effects
/// are calls to the app's conflict and change-token resolvers, and writing the resolved fields
/// into the server's copy of a conflicted record, which is the record that gets sent again.
struct FailureResolver {
    /// The function handler that will be called to resolve record conflicts.
    let resolveConflict: ConflictResolver?

    /// The function handler that will be called when the change token should be expired.
    let resolveExpiredChangeToken: ChangeTokenExpiredResolver?

    func resolution(for error: Error, work: SyncWork) -> FailureResolution<CloudKitBackend> {
        if let ckError = error as? CKError {
            Log.error.error("Handling CloudKit error (code \(ckError.errorCode)): \(ckError.localizedDescription)")

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
                    modifiedOperation.changeToken = resolveExpiredChangeToken?()

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

                    return resolution(for: error, work: work)
                case let .modify(operation):
                    // Supported modify partial failures: batchRequestFailed and serverRecordChanged

                    guard let partialErrorsByRecordID = ckError.partialErrorsByItemID as? [CKRecord.ID: Error] else {
                        return .halt(error)
                    }

                    let recordIDsNotSavedOrDeleted = Set(partialErrorsByRecordID.keys)

                    let partialErrors = partialErrorsByRecordID.compactMap { $0.value as? CKError }

                    if ckError.indicatesShouldBackoff {
                        return .retry(work, error, ckError.suggestedBackoffSeconds)
                    }

                    let unhandleableErrorsByItemID = partialErrors
                        .filter { error in

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
                        partialErrorsByRecordID
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
                        partialErrorsByRecordID
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
                        .filter { error in
                            if error.code == .serverRecordChanged {
                                return true
                            }

                            return false
                        }

                    // Resolved records
                    let resolvedConflictsToSave = serverRecordChangedErrors
                        .compactMap { error in
                            self.resolvedRecord(for: error)
                        }

                    if resolvedConflictsToSave.count != serverRecordChangedErrors.count {
                        // Abort if couldn't handle conflict for some reason
                        Log.error.error("Aborting since count of resolved records not equal to number of server record changed errors")

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

                    return .resend(records: allResolvedRecordsToSave, recordIDsToDelete: recordIDsToDeleteWithoutUnknowns)
                default:
                    return .halt(error)
                }
            case .serverRecordChanged:
                guard let resolvedConflictToSave = resolvedRecord(for: error) else {
                    // If couldn't handle conflict for the records, abort
                    return .halt(error)
                }

                return .resend(records: [resolvedConflictToSave], recordIDsToDelete: [])
            case .limitExceeded:
                return .split(error)
            case .zoneNotFound, .userDeletedZone:
                return .redoSetup(.zone, error)
            case .assetNotAvailable,
                 .assetFileNotFound,
                 .assetFileModified,
                 .participantMayNeedVerification,
                 .participantAlreadyInvited,
                 .alreadyShared,
                 .tooManyParticipants,
                 .unknownItem,
                 .operationCancelled,
                 .accountTemporarilyUnavailable:
                return .halt(error)
            @unknown default:
                // A code this version of the library does not know. Halting keeps the work
                // queued; anything else risks dropping it.
                return .halt(error)
            }
        } else {
            return .halt(error)
        }
    }

    /// Runs the app's conflict resolver for one `serverRecordChanged` error and returns the record to save.
    func resolvedRecord(for error: Error) -> CKRecord? {
        guard let effectiveError = error as? CKError else {
            Log.error.critical("resolveConflict called on an error that was not a CKError. The error was \(String(describing: error))")

            return nil
        }

        guard effectiveError.code == .serverRecordChanged else {
            Log.error.critical("resolveConflict called on a CKError that was not a serverRecordChanged error. The error was \(String(describing: effectiveError))")

            return nil
        }

        guard let clientRecord = effectiveError.clientRecord else {
            Log.error.critical("Failed to obtain client record from serverRecordChanged error. The error was \(String(describing: effectiveError))")

            return nil
        }

        guard let serverRecord = effectiveError.serverRecord else {
            Log.error.critical("Failed to obtain server record from serverRecordChanged error. The error was \(String(describing: effectiveError))")

            return nil
        }

        Log.error.error("CloudKit conflict with record of type \(serverRecord.recordType). Running conflict resolver")

        guard let resolveConflict else {
            return nil
        }

        guard let resolvedRecord = resolveConflict(clientRecord, serverRecord) else {
            return nil
        }

        if serverRecord != resolvedRecord {
            // Always return the server record so we don't end up in a conflict loop.
            // The server record has the change tag we want to use.
            // https://developer.apple.com/documentation/cloudkit/ckerror/2325208-serverrecordchanged

            // First, nil out all keys in case any keys in the newly resolved record are nil,
            // we don't want those to carry over into the final resolved copy
            serverRecord.removeAllFields()

            serverRecord.copyFields(from: resolvedRecord)
        }

        return serverRecord
    }
}
