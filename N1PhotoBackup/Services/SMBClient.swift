import Foundation
import AMSMB2

/// SMB / Samba（工程已链接 AMSMB2，直接可用）
final class SMBStorageClient: StorageClient {
    private let server: StorageServer
    private let credentials: ServerCredentials

    init(server: StorageServer, credentials: ServerCredentials) {
        self.server = server
        self.credentials = credentials
    }

    func testConnection() async throws {
        let manager = try makeManager()
        do {
            try await manager.connectShare(name: server.normalizedShareName)
            defer { manager.disconnectShare() }
            let root = server.normalizedBasePath
            _ = try await manager.contentsOfDirectory(atPath: root.isEmpty ? "/" : root)
        } catch {
            throw StorageError.connectionFailed(friendly(error))
        }
    }

    func remoteExists(relativePath: String) async throws -> Bool {
        let path = normalizeSMBPath(server.joinedRemotePath(relativePath))
        let manager = try makeManager()
        do {
            try await manager.connectShare(name: server.normalizedShareName)
            defer { manager.disconnectShare() }
            _ = try await manager.attributesOfItem(atPath: path)
            return true
        } catch {
            return false
        }
    }

    func ensureDirectories(relativeDir: String) async throws {
        let full = normalizeSMBPath(server.joinedRemotePath(relativeDir))
        let parts = full.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }

        let manager = try makeManager()
        do {
            try await manager.connectShare(name: server.normalizedShareName)
            defer { manager.disconnectShare() }
            var built = ""
            for part in parts {
                built = built.isEmpty ? part : "\(built)/\(part)"
                do {
                    try await manager.createDirectory(atPath: built)
                } catch {
                    // 已存在
                }
            }
        } catch {
            throw StorageError.remote(friendly(error))
        }
    }

    func uploadFile(
        localURL: URL,
        relativePath: String,
        contentType: String?,
        progress: ((Double) -> Void)?
    ) async throws {
        let parent = (relativePath as NSString).deletingLastPathComponent
        if !parent.isEmpty && parent != "." {
            try await ensureDirectories(relativeDir: parent)
        }

        let path = normalizeSMBPath(server.joinedRemotePath(relativePath))
        let data = try Data(contentsOf: localURL)
        let total = max(Double(data.count), 1)

        let manager = try makeManager()
        do {
            try await manager.connectShare(name: server.normalizedShareName)
            defer { manager.disconnectShare() }

            try await manager.write(
                data: data,
                progress: { sent in
                    progress?(min(Double(sent) / total, 1))
                    return true
                },
                toPath: path
            )
            progress?(1)
        } catch {
            throw StorageError.remote(friendly(error))
        }
    }

    // MARK: -

    private func makeManager() throws -> SMB2Manager {
        let host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw StorageError.invalidConfiguration("主机不能为空")
        }
        guard !server.normalizedShareName.isEmpty else {
            throw StorageError.invalidConfiguration("请填写 SMB 共享名（iStoreOS Samba 里配置的名称，如 sda1）")
        }

        var components = URLComponents()
        components.scheme = "smb"
        components.host = host
        if server.port > 0, server.port != 445 {
            components.port = server.port
        }
        guard let url = components.url else {
            throw StorageError.invalidConfiguration("SMB 地址无效")
        }

        let credential = URLCredential(
            user: composedUsername(),
            password: credentials.password,
            persistence: .forSession
        )
        guard let manager = SMB2Manager(url: url, credential: credential) else {
            throw StorageError.connectionFailed("无法创建 SMB 连接")
        }
        manager.timeout = 120
        return manager
    }

    private func composedUsername() -> String {
        let user = server.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = server.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if domain.isEmpty || user.contains("\\") { return user }
        return "\(domain)\\\(user)"
    }

    private func normalizeSMBPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    private func friendly(_ error: Error) -> String {
        let msg = error.localizedDescription
        if msg.localizedCaseInsensitiveContains("auth") || msg.localizedCaseInsensitiveContains("logon") {
            return "认证失败：检查 Samba 用户名/密码，以及是否允许该用户访问共享"
        }
        if msg.localizedCaseInsensitiveContains("timed out") || msg.localizedCaseInsensitiveContains("timeout") {
            return "连接超时：确认 445 端口开放，手机与 N1 同一 Wi‑Fi"
        }
        if msg.localizedCaseInsensitiveContains("not found") || msg.localizedCaseInsensitiveContains("no such") {
            return "共享或路径不存在：检查「共享名」与「共享内路径」"
        }
        return msg
    }
}
