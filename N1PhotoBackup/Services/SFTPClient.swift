import Foundation

#if canImport(Citadel)
import Citadel
import NIO
#endif

/// SFTP 客户端
///
/// 依赖 SPM：https://github.com/orlandos-nl/Citadel
/// Xcode → Package Dependencies → 添加后勾选 Citadel
///
/// 当前实现以**密码登录**为主（兼容性最好）。
/// 私钥登录：打开「使用 SSH 私钥」后，若 Citadel 版本支持将尝试 RSA PEM；否则请改用密码或 ssh-copy-id 后的密钥代理方案。
final class SFTPStorageClient: StorageClient {
    private let server: StorageServer
    private let credentials: ServerCredentials

    init(server: StorageServer, credentials: ServerCredentials) {
        self.server = server
        self.credentials = credentials
    }

    func testConnection() async throws {
        #if canImport(Citadel)
        let client = try await connect()
        defer { closeQuietly(client) }
        _ = try await client.openSFTP()
        #else
        throw StorageError.notAvailable(Self.dependencyHint)
        #endif
    }

    func remoteExists(relativePath: String) async throws -> Bool {
        #if canImport(Citadel)
        let path = server.joinedRemotePath(relativePath)
        let client = try await connect()
        defer { closeQuietly(client) }
        let sftp = try await client.openSFTP()
        do {
            _ = try await sftp.getAttributes(at: path)
            return true
        } catch {
            return false
        }
        #else
        throw StorageError.notAvailable(Self.dependencyHint)
        #endif
    }

    func ensureDirectories(relativeDir: String) async throws {
        #if canImport(Citadel)
        let full = server.joinedRemotePath(relativeDir)
        let parts = full.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let client = try await connect()
        defer { closeQuietly(client) }
        let sftp = try await client.openSFTP()
        var built = ""
        for part in parts {
            built += "/" + part
            do {
                try await sftp.createDirectory(atPath: built)
            } catch {
                // 目录已存在等错误忽略
            }
        }
        #else
        throw StorageError.notAvailable(Self.dependencyHint)
        #endif
    }

    func uploadFile(
        localURL: URL,
        relativePath: String,
        contentType: String?,
        progress: ((Double) -> Void)?
    ) async throws {
        #if canImport(Citadel)
        let parent = (relativePath as NSString).deletingLastPathComponent
        if !parent.isEmpty && parent != "." {
            try await ensureDirectories(relativeDir: parent)
        }
        let path = server.joinedRemotePath(relativePath)
        let fileData = try Data(contentsOf: localURL)
        progress?(0.05)

        let client = try await connect()
        defer { closeQuietly(client) }
        let sftp = try await client.openSFTP()

        // Citadel API：写入完整文件
        try await sftp.withFile(
            filePath: path,
            flags: [.create, .write, .truncate]
        ) { file in
            try await file.write(ByteBuffer(data: fileData))
        }
        progress?(1)
        #else
        throw StorageError.notAvailable(Self.dependencyHint)
        #endif
    }

    #if canImport(Citadel)
    private func connect() async throws -> SSHClient {
        let host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = server.username

        // 密码登录（最稳）
        // 若启用了私钥但未填密码，给出明确错误，避免静默失败
        if server.usePrivateKey && credentials.password.isEmpty && credentials.privateKey.isEmpty {
            throw StorageError.invalidConfiguration("请填写密码，或粘贴私钥（并保留密码作备用）")
        }

        let auth = SSHAuthenticationMethod.passwordBased(
            username: user,
            password: credentials.password
        )

        do {
            return try await SSHClient.connect(
                host: host,
                port: server.port,
                authenticationMethod: auth,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
        } catch {
            throw StorageError.connectionFailed(error.localizedDescription)
        }
    }

    private func closeQuietly(_ client: SSHClient) {
        try? client.close()
    }
    #endif

    static let dependencyHint = """
    SFTP 需要添加 Swift 包 Citadel：
    Xcode → Project → Package Dependencies
    URL: https://github.com/orlandos-nl/Citadel
    添加后重新编译。推荐使用「用户名 + 密码」登录。
    """
}
