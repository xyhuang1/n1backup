import Foundation
import Citadel
import NIOCore

/// SFTP 客户端（Citadel）
/// SSH/SFTP 会话在客户端生命周期内复用，操作经 SerialExecutor 串行。
final class SFTPStorageClient: StorageClient, @unchecked Sendable {
    private let server: StorageServer
    private let credentials: ServerCredentials
    private let gate = SerialExecutor()

    private var ssh: SSHClient?
    private var sftp: SFTPClient?
    private var ensuredDirs = Set<String>()

    init(server: StorageServer, credentials: ServerCredentials) {
        self.server = server
        self.credentials = credentials
    }

    func close() async {
        await gate.run { [self] in
            await tearDown()
        }
    }

    func testConnection() async throws {
        try await gate.run { [self] in
            let sftp = try await ensureSFTP()
            let path = server.normalizedBasePath
            do {
                _ = try await sftp.listDirectory(atPath: path.isEmpty ? "/" : path)
            } catch {
                // 基础目录可能尚未创建，至少确认能列 /
                do {
                    _ = try await sftp.listDirectory(atPath: "/")
                } catch {
                    throw StorageError.connectionFailed(friendly(error))
                }
            }
        }
    }

    func remoteExists(relativePath: String) async throws -> Bool {
        try await gate.run { [self] in
            let path = server.joinedRemotePath(relativePath)
            let sftp = try await ensureSFTP()
            do {
                _ = try await sftp.getAttributes(at: path)
                return true
            } catch {
                return false
            }
        }
    }

    func ensureDirectories(relativeDir: String) async throws {
        try await gate.run { [self] in
            let full = server.joinedRemotePath(relativeDir)
            if ensuredDirs.contains(full) { return }

            let parts = full.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard !parts.isEmpty else { return }

            let sftp = try await ensureSFTP()
            var built = ""
            for part in parts {
                built += "/" + part
                if ensuredDirs.contains(built) { continue }
                do {
                    try await sftp.createDirectory(atPath: built)
                } catch {
                    // 已存在
                }
                ensuredDirs.insert(built)
            }
            ensuredDirs.insert(full)
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

        let path = server.joinedRemotePath(relativePath)
        // mappedIfSafe 减少大文件内存拷贝
        let fileData = try Data(contentsOf: localURL, options: [.mappedIfSafe])
        progress?(0.05)

        try await gate.run { [self] in
            do {
                let sftp = try await ensureSFTP()
                try await sftp.withFile(
                    filePath: path,
                    flags: [.write, .create, .truncate]
                ) { file in
                    var buffer = ByteBufferAllocator().buffer(capacity: fileData.count)
                    buffer.writeBytes(fileData)
                    try await file.write(buffer)
                }
                progress?(1)
            } catch let e as StorageError {
                await tearDown()
                throw e
            } catch {
                await tearDown()
                throw StorageError.remote(friendly(error))
            }
        }
    }

    // MARK: - Connection

    private func ensureSFTP() async throws -> SFTPClient {
        if let sftp { return sftp }

        let host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw StorageError.invalidConfiguration("主机不能为空")
        }
        let user = server.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else {
            throw StorageError.invalidConfiguration("SFTP 用户名不能为空")
        }

        if server.usePrivateKey, credentials.password.isEmpty, !credentials.privateKey.isEmpty {
            throw StorageError.invalidConfiguration(
                "当前版本优先支持密码登录。请关闭「使用 SSH 私钥」，填写 SSH 密码后重试（或在 N1 上为该用户设置密码）。"
            )
        }
        if credentials.password.isEmpty {
            throw StorageError.invalidConfiguration("请填写 SSH/SFTP 密码")
        }

        let port = server.port > 0 ? server.port : 22
        let auth = SSHAuthenticationMethod.passwordBased(
            username: user,
            password: credentials.password
        )

        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: auth,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
        } catch {
            throw StorageError.connectionFailed(friendly(error))
        }

        do {
            let session = try await client.openSFTP()
            ssh = client
            sftp = session
            return session
        } catch {
            try? await client.close()
            ssh = nil
            sftp = nil
            throw StorageError.connectionFailed(friendly(error))
        }
    }

    private func tearDown() async {
        sftp = nil
        if let ssh {
            try? await ssh.close()
        }
        self.ssh = nil
        ensuredDirs.removeAll()
    }

    private func friendly(_ error: Error) -> String {
        let msg = error.localizedDescription
        if msg.localizedCaseInsensitiveContains("auth")
            || msg.localizedCaseInsensitiveContains("permission")
            || msg.localizedCaseInsensitiveContains("denied") {
            return "认证失败或无权限：请检查用户名/密码，以及目录写权限"
        }
        if msg.localizedCaseInsensitiveContains("timed out")
            || msg.localizedCaseInsensitiveContains("timeout") {
            return "连接超时：确认 N1 SSH 已开启，端口正确，与手机同一局域网"
        }
        return msg
    }
}
