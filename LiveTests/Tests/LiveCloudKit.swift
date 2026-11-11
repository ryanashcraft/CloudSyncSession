import CloudKit
import XCTest

/// Access to the container these tests run against, and the throwaway zone each test works in.
enum LiveCloudKit {
    static var container: CKContainer {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "LiveTestsContainerID") as? String, !identifier.isEmpty else {
            fatalError("The host app's Info.plist has no LiveTestsContainerID. Set LIVE_TESTS_CONTAINER_ID in Local.xcconfig.")
        }

        return CKContainer(identifier: identifier)
    }

    static var database: CKDatabase {
        container.privateCloudDatabase
    }

    /// Skips the test unless the device is signed in to an iCloud account that can use CloudKit.
    static func requireAccount() async throws {
        let status = try await container.accountStatus()

        try XCTSkipUnless(status == .available, "iCloud account is not available (status \(status.rawValue)). Sign in to iCloud to run the live tests.")
    }

    static func makeZoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "LiveTests-\(UUID().uuidString)", ownerName: CKCurrentUserDefaultName)
    }

    static func createZone(_ zoneID: CKRecordZone.ID) async throws {
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
    }

    /// Deletes the zone, ignoring the error if it is already gone.
    static func deleteZone(_ zoneID: CKRecordZone.ID) async {
        _ = try? await database.deleteRecordZone(withID: zoneID)
    }

    static func zoneExists(_ zoneID: CKRecordZone.ID) async throws -> Bool {
        do {
            _ = try await database.recordZone(for: zoneID)

            return true
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            return false
        }
    }

    static func makeRecords(_ count: Int, in zoneID: CKRecordZone.ID) -> [CKRecord] {
        (0 ..< count).map { index in
            let record = CKRecord(recordType: "LiveTest", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
            record["index"] = index
            record["payload"] = String(repeating: "x", count: 2000)

            return record
        }
    }

    /// How many records the zone holds.
    static func recordCount(in zoneID: CKRecordZone.ID) async throws -> Int {
        var count = 0
        var token: CKServerChangeToken?
        var moreComing = true

        while moreComing {
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)

            count += changes.modificationResultsByID.count
            token = changes.changeToken
            moreComing = changes.moreComing
        }

        return count
    }
}

/// Records something the test saw, as a line in the test log.
func noteObservation(_ text: String) {
    print("LIVE-OBSERVATION: \(text)")
}

func describe(_ error: Error?) -> String {
    guard let error else {
        return "no error"
    }

    guard let ckError = error as? CKError else {
        return "non-CloudKit error \(error)"
    }

    let partial = (ckError.partialErrorsByItemID ?? [:]).values
        .compactMap { ($0 as? CKError)?.code.rawValue }
        .reduce(into: [Int: Int]()) { $0[$1, default: 0] += 1 }

    return "CKError code \(ckError.code.rawValue)" + (partial.isEmpty ? "" : ", per-item codes (code: count) \(partial)")
}

/// Thread-safe notes about one operation, written from CloudKit's callback threads.
final class Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func add(_ entry: String) {
        lock.lock()
        defer { lock.unlock() }

        entries.append(entry)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }

        return entries
    }
}
