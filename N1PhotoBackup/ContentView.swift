import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("备份", systemImage: "arrow.up.circle.fill")
                }

            UploadQueueView()
                .tabItem {
                    Label("队列", systemImage: "list.bullet.rectangle")
                }

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
        }
        .tint(.blue)
    }
}

#Preview {
    ContentView()
        .environmentObject(UploadManager.shared)
        .environmentObject(ServerStore.shared)
}
