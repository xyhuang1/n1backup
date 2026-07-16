import Foundation
import Security

enum KeychainStore {
    private static let service = "com.n1photobackup.credentials"

    // MARK: - 通用字符串

    @discardableResult
    static func save(account: String, value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - 按服务器 ID 存凭据

    private struct Payload: Codable {
        var password: String
        var privateKey: String
        var passphrase: String
    }

    static func saveCredentials(serverId: UUID, credentials: ServerCredentials) {
        let payload = Payload(
            password: credentials.password,
            privateKey: credentials.privateKey,
            passphrase: credentials.passphrase
        )
        guard let data = try? JSONEncoder().encode(payload),
              let raw = String(data: data, encoding: .utf8) else { return }
        save(account: "server.\(serverId.uuidString)", value: raw)
    }

    static func readCredentials(serverId: UUID) -> ServerCredentials {
        guard let raw = read(account: "server.\(serverId.uuidString)"),
              let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return .empty
        }
        return ServerCredentials(
            password: payload.password,
            privateKey: payload.privateKey,
            passphrase: payload.passphrase
        )
    }

    static func deleteCredentials(serverId: UUID) {
        delete(account: "server.\(serverId.uuidString)")
    }
}
