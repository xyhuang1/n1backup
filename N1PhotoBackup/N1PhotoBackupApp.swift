import SwiftUI

@main
struct N1PhotoBackupApp: App {
    @StateObject private var uploadManager = UploadManager.shared
    @StateObject private var serverStore = ServerStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(uploadManager)
                .environmentObject(serverStore)
        }
    }
}
