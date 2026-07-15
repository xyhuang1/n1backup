import Foundation

enum StorageError: LocalizedError {
    case invalidConfiguration(String)
    case notAvailable(String)
    case connectionFailed(String)
    case authFailed
    case httpStatus(Int, String?)
    case transport(Error)
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let m): return "配置无效：\(m)"
        case .notAvailable(let m): return m
        case .connectionFailed(let m): return "连接失败：\(m)"
        case .authFailed: return "认证失败，请检查用户名/密码或密钥"
        case .httpStatus(let c, let b):
            if let b, !b.isEmpty { return "HTTP \(c)：\(b.prefix(120))" }
            return "HTTP \(c)"
        case .transport(let e): return e.localizedDescription
        case .remote(let m): return m
        }
    }
}

/// 统一存储上传接口，各协议各自实现
protocol StorageClient: AnyObject {
    /// 测试连通与鉴权
    func testConnection() async throws

    /// 远端相对「备份根」的路径是否已存在文件
    func remoteExists(relativePath: String) async throws -> Bool

    /// 确保目录（相对备份根，如 `2026/07`）
    func ensureDirectories(relativeDir: String) async throws

    /// 上传本地文件到相对路径（含文件名，如 `2026/07/IMG.HEIC`）
    func uploadFile(
        localURL: URL,
        relativePath: String,
        contentType: String?,
        progress: ((Double) -> Void)?
    ) async throws
}

enum StorageClientFactory {
    static func make(server: StorageServer, credentials: ServerCredentials) throws -> StorageClient {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StorageError.invalidConfiguration("主机地址不能为空")
        }
        switch server.protocolKind {
        case .webdav:
            return WebDAVStorageClient(server: server, credentials: credentials)
        case .smb:
            return SMBStorageClient(server: server, credentials: credentials)
        case .sftp:
            return SFTPStorageClient(server: server, credentials: credentials)
        case .ftp:
            return FTPStorageClient(server: server, credentials: credentials)
        }
    }
}
