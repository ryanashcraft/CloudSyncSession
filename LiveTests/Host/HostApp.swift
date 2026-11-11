import SwiftUI

/// Exists only to carry the CloudKit entitlement for the tests that run inside it.
@main
struct HostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("CloudSyncSession live tests")
                .padding()
        }
    }
}
