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
        case .authFailed: return "认证失败，请检查用户名/密码"
        case .httpStatus(let c, let b):
            if let b, !b.isEmpty { return "HTTP \(c)：\(b.prefix(120))" }
            return "HTTP \(c)"
        case .transport(let e): return e.localizedDescription
        case .remote(let m): return m
        }
    }
}

/// 统一存储上传接口
protocol StorageClient: AnyObject {
    func testConnection() async throws
    func remoteExists(relativePath: String) async throws -> Bool
    func ensureDirectories(relativeDir: String) async throws
    func uploadFile(
        localURL: URL,
        relativePath: String,
        contentType: String?,
        progress: ((Double) -> Void)?
    ) async throws
}

enum StorageClientFactory {
    static func make(server: StorageServer, credentials: ServerCredentials) throws -> StorageClient {
        let host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
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
