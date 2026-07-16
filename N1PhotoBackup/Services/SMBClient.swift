import Foundation
import AMSMB2

/// SMB / Samba（AMSMB2 4.0.x）
/// 连接在客户端生命周期内复用，操作经 SerialExecutor 串行，避免并发写冲突。
final class SMBStorageClient: StorageClient, @unchecked Sendable {
    private let server: StorageServer
    private let credentials: ServerCredentials
    private let gate = SerialExecutor()

    private var manager: SMB2Manager?
    private var shareConnected = false
    private var ensuredDirs = Set<String>()

    init(server: StorageServer, credentials: ServerCredentials) {
        self.server = server
        self.credentials = credentials
    }

    func close() async {
        await gate.run { [self] in
            if shareConnected, let manager {
                try? await manager.disconnectShare()
                shareConnected = false
            }
            self.manager = nil
            ensuredDirs.removeAll()
        }
    }

    func testConnection() async throws {
        try await gate.run { [self] in
            let mgr = try await ensureConnected()
            let root = normalizeSMBPath(server.normalizedBasePath)
            do {
                _ = try await mgr.contentsOfDirectory(atPath: root.isEmpty ? "/" : root)
            } catch {
                // 根路径不存在时，至少验证共享可连
                do {
                    _ = try await mgr.contentsOfDirectory(atPath: "/")
                } catch {
                    throw StorageError.connectionFailed(friendly(error))
                }
            }
        }
    }

    func remoteExists(relativePath: String) async throws -> Bool {
        try await gate.run { [self] in
            let path = normalizeSMBPath(server.joinedRemotePath(relativePath))
            let mgr = try await ensureConnected()
            do {
                _ = try await mgr.attributesOfItem(atPath: path)
                return true
            } catch {
                return false
            }
        }
    }

    func ensureDirectories(relativeDir: String) async throws {
        try await gate.run { [self] in
            let full = normalizeSMBPath(server.joinedRemotePath(relativeDir))
            if ensuredDirs.contains(full) { return }

            let parts = full.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard !parts.isEmpty else { return }

            let mgr = try await ensureConnected()
            do {
                var built = ""
                for part in parts {
                    built = built.isEmpty ? part : "\(built)/\(part)"
                    if ensuredDirs.contains(built) { continue }
                    do {
                        try await mgr.createDirectory(atPath: built)
                    } catch {
                        // 已存在
                    }
                    ensuredDirs.insert(built)
                }
                ensuredDirs.insert(full)
            } catch {
                throw StorageError.remote(friendly(error))
            }
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

        let data = try Data(contentsOf: localURL, options: [.mappedIfSafe])
        let total = max(Double(data.count), 1)
        let path = normalizeSMBPath(server.joinedRemotePath(relativePath))

        try await gate.run { [self] in
            let mgr = try await ensureConnected()
            do {
                // AMSMB2 4.0：write(data:toPath:progress:)
                try await mgr.write(
                    data: data,
                    toPath: path,
                    progress: { sent in
                        progress?(min(Double(sent) / total, 1))
                        return true
                    }
                )
                progress?(1)
            } catch {
                // 连接可能已断，下次 ensureConnected 重建
                shareConnected = false
                manager = nil
                throw StorageError.remote(friendly(error))
            }
        }
    }

    // MARK: - Connection

    private func ensureConnected() async throws -> SMB2Manager {
        if let manager, shareConnected {
            return manager
        }
        let mgr = try makeManager()
        do {
            try await mgr.connectShare(name: server.normalizedShareName)
        } catch {
            throw StorageError.connectionFailed(friendly(error))
        }
        manager = mgr
        shareConnected = true
        return mgr
    }

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
