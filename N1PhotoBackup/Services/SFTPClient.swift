import Foundation
import Citadel
import NIOCore

/// SFTP 客户端（Citadel，工程已通过 SPM 链接，开箱即用）
final class SFTPStorageClient: StorageClient {
    private let server: StorageServer
    private let credentials: ServerCredentials

    init(server: StorageServer, credentials: ServerCredentials) {
        self.server = server
        self.credentials = credentials
    }

    func testConnection() async throws {
        try await withSFTP { sftp in
            let path = self.server.normalizedBasePath
            // 列一下基础目录；不存在时尝试列 /
            do {
                _ = try await sftp.listDirectory(atPath: path.isEmpty ? "/" : path)
            } catch {
                _ = try await sftp.listDirectory(atPath: "/")
            }
        }
    }

    func remoteExists(relativePath: String) async throws -> Bool {
        let path = server.joinedRemotePath(relativePath)
        return try await withSFTP { sftp in
            do {
                _ = try await sftp.getAttributes(at: path)
                return true
            } catch {
                return false
            }
        }
    }

    func ensureDirectories(relativeDir: String) async throws {
        let full = server.joinedRemotePath(relativeDir)
        let parts = full.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }

        try await withSFTP { sftp in
            var built = ""
            for part in parts {
                built += "/" + part
                do {
                    try await sftp.createDirectory(atPath: built)
                } catch {
                    // 已存在
                }
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

        let path = server.joinedRemotePath(relativePath)
        let fileData = try Data(contentsOf: localURL)
        progress?(0.05)

        try await withSFTP { sftp in
            try await sftp.withFile(
                filePath: path,
                flags: [.write, .create, .truncate]
            ) { file in
                var buffer = ByteBufferAllocator().buffer(capacity: fileData.count)
                buffer.writeBytes(fileData)
                try await file.write(buffer)
            }
        }
        progress?(1)
    }

    // MARK: - Connection

    private func withSFTP<T: Sendable>(
        _ body: @Sendable (SFTPClient) async throws -> T
    ) async throws -> T {
        let host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw StorageError.invalidConfiguration("主机不能为空")
        }
        let user = server.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else {
            throw StorageError.invalidConfiguration("SFTP 用户名不能为空")
        }

        // 私钥登录：Citadel 版本差异大，优先密码；有私钥且密码为空时给出明确提示
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

        let ssh: SSHClient
        do {
            ssh = try await SSHClient.connect(
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
            let sftp = try await ssh.openSFTP()
            do {
                let result = try await body(sftp)
                try? await ssh.close()
                return result
            } catch {
                try? await ssh.close()
                throw StorageError.remote(friendly(error))
            }
        } catch let e as StorageError {
            try? await ssh.close()
            throw e
        } catch {
            try? await ssh.close()
            throw StorageError.connectionFailed(friendly(error))
        }
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
