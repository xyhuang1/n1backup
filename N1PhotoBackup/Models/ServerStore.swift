import Foundation
import Combine

/// 多台备份服务器（SFTP / WebDAV）+ 当前选中项
@MainActor
final class ServerStore: ObservableObject {
    static let shared = ServerStore()

    @Published private(set) var servers: [StorageServer] = []
    @Published var selectedServerId: UUID?

    private let serversKey = "storage_servers_v2"
    private let selectedKey = "storage_selected_server_v2"

    private init() {
        load()
    }

    var selectedServer: StorageServer? {
        guard let id = selectedServerId else { return servers.first }
        return servers.first(where: { $0.id == id }) ?? servers.first
    }

    func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: serversKey),
           let list = try? JSONDecoder().decode([StorageServer].self, from: data) {
            servers = list.sorted { $0.updatedAt > $1.updatedAt }
        } else {
            servers = []
        }
        if let raw = defaults.string(forKey: selectedKey), let id = UUID(uuidString: raw) {
            selectedServerId = id
        } else {
            selectedServerId = servers.first?.id
        }
    }

    func saveList() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: serversKey)
        }
        if let id = selectedServerId {
            UserDefaults.standard.set(id.uuidString, forKey: selectedKey)
        }
    }

    func select(_ id: UUID) {
        selectedServerId = id
        saveList()
    }

    func upsert(_ server: StorageServer, credentials: ServerCredentials) {
        var s = server
        s.touch()
        if let idx = servers.firstIndex(where: { $0.id == s.id }) {
            servers[idx] = s
        } else {
            servers.insert(s, at: 0)
        }
        KeychainStore.saveCredentials(serverId: s.id, credentials: credentials)
        if selectedServerId == nil {
            selectedServerId = s.id
        }
        saveList()
    }

    func delete(id: UUID) {
        servers.removeAll { $0.id == id }
        KeychainStore.deleteCredentials(serverId: id)
        if selectedServerId == id {
            selectedServerId = servers.first?.id
        }
        saveList()
    }

    func credentials(for id: UUID) -> ServerCredentials {
        KeychainStore.readCredentials(serverId: id)
    }

    func credentials(for server: StorageServer) -> ServerCredentials {
        credentials(for: server.id)
    }
}
