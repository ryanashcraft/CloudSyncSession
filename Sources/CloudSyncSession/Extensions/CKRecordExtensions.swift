import CloudKit

extension CKRecord {
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
