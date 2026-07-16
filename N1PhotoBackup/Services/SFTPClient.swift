import Foundation
import Citadel
import Crypto
import NIOCore

/// SFTP 客户端（Citadel 0.12.x）
/// SSH/SFTP 会话在客户端生命周期内复用，操作经 SerialExecutor 串行。
/// 支持：密码登录、OpenSSH 格式私钥（ed25519 / RSA）。
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
            let path = normalized(server.normalizedBasePath)
            do {
                _ = try await sftp.listDirectory(atPath: path)
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
            let path = normalized(server.joinedRemotePath(relativePath))
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
            let full = normalized(server.joinedRemotePath(relativeDir))
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

        let path = normalized(server.joinedRemotePath(relativePath))
        let fileData = try Data(contentsOf: localURL, options: [.mappedIfSafe])
        progress?(0.05)

        try await gate.run { [self] in
            do {
                let sftp = try await ensureSFTP()
                // write + create + truncate：覆盖已有文件
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

        let auth: SSHAuthenticationMethod
        do {
            auth = try makeAuth(username: user)
        } catch let e as StorageError {
            throw e
        } catch {
            throw StorageError.invalidConfiguration("私钥解析失败：\(error.localizedDescription)")
        }

        let port = server.port > 0 ? server.port : 22
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

    /// 密码 或 OpenSSH 私钥（ed25519 / RSA）
    private func makeAuth(username user: String) throws -> SSHAuthenticationMethod {
        let keyText = credentials.privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantKey = server.usePrivateKey || !keyText.isEmpty

        if wantKey {
            guard !keyText.isEmpty else {
                throw StorageError.invalidConfiguration("已开启私钥登录，请粘贴 OpenSSH 私钥正文")
            }
            if keyText.contains("BEGIN RSA PRIVATE KEY")
                || keyText.contains("BEGIN EC PRIVATE KEY")
                || (keyText.contains("BEGIN PRIVATE KEY") && !keyText.contains("OPENSSH")) {
                throw StorageError.invalidConfiguration(
                    "请使用 OpenSSH 格式私钥（ssh-keygen 默认输出，开头为 -----BEGIN OPENSSH PRIVATE KEY-----）。可用 `ssh-keygen -p -m rfc4718` 或重新生成。"
                )
            }

            let decryptionKey: Data? = credentials.passphrase.isEmpty
                ? nil
                : Data(credentials.passphrase.utf8)

            // 优先用官方检测；失败则按常见类型依次尝试
            if keyText.contains("BEGIN OPENSSH PRIVATE KEY"),
               let type = try? SSHKeyDetection.detectPrivateKeyType(from: keyText) {
                if type == .ed25519 {
                    let pk = try Curve25519.Signing.PrivateKey(
                        sshEd25519: keyText,
                        decryptionKey: decryptionKey
                    )
                    return .ed25519(username: user, privateKey: pk)
                }
                if type == .rsa {
                    let pk = try Insecure.RSA.PrivateKey(
                        sshRsa: keyText,
                        decryptionKey: decryptionKey
                    )
                    return .rsa(username: user, privateKey: pk)
                }
                throw StorageError.invalidConfiguration(
                    "暂不支持 \(type.description) 私钥，请改用 ed25519 / RSA，或改用密码登录"
                )
            }

            // 检测失败时回退尝试
            if let pk = try? Curve25519.Signing.PrivateKey(sshEd25519: keyText, decryptionKey: decryptionKey) {
                return .ed25519(username: user, privateKey: pk)
            }
            if let pk = try? Insecure.RSA.PrivateKey(sshRsa: keyText, decryptionKey: decryptionKey) {
                return .rsa(username: user, privateKey: pk)
            }

            throw StorageError.invalidConfiguration(
                "无法解析私钥。请确认是 OpenSSH 格式（ed25519/RSA），口令正确；或改用密码登录。"
            )
        }

        if credentials.password.isEmpty {
            throw StorageError.invalidConfiguration("请填写 SSH/SFTP 密码，或开启「使用 SSH 私钥」并粘贴私钥")
        }
        return .passwordBased(username: user, password: credentials.password)
    }

    private func tearDown() async {
        sftp = nil
        if let ssh {
            try? await ssh.close()
        }
        self.ssh = nil
        ensuredDirs.removeAll()
    }

    private func normalized(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return "/" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private func friendly(_ error: Error) -> String {
        let msg = error.localizedDescription
        if msg.localizedCaseInsensitiveContains("auth")
            || msg.localizedCaseInsensitiveContains("permission")
            || msg.localizedCaseInsensitiveContains("denied")
            || msg.localizedCaseInsensitiveContains("authentication") {
            return "认证失败或无权限：请检查用户名/密码/私钥，以及目录写权限"
        }
        if msg.localizedCaseInsensitiveContains("timed out")
            || msg.localizedCaseInsensitiveContains("timeout") {
            return "连接超时：确认 N1 SSH 已开启，端口正确，与手机同一局域网"
        }
        return msg
    }
}
