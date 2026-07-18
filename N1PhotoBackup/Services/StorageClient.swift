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
        case .authFailed: return "认证失败，请检查用户名/密码或私钥"
        case .httpStatus(let c, let b):
            let hint: String
            switch c {
            case 404:
                hint = "路径不存在。WebDAV 请核对基础路径（AList 常为 /dav/存储名/...），或先在服务端建好目录"
            case 405:
                hint = "方法不被允许。可能路径不是 WebDAV 端点，或反向代理禁用了 PROPFIND；请确认端口与 /dav 路径"
            case 401, 403:
                hint = "无权限，请检查账号密码与路径权限"
            case 501:
                hint = "服务端未实现该 WebDAV 方法"
            case 502, 503, 504:
                hint = "网关/服务暂时不可用"
            default:
                hint = ""
            }
            if let b, !b.isEmpty {
                let body = String(b.prefix(80)).replacingOccurrences(of: "\n", with: " ")
                return hint.isEmpty ? "HTTP \(c)：\(body)" : "HTTP \(c)：\(hint)（\(body)）"
            }
            return hint.isEmpty ? "HTTP \(c)" : "HTTP \(c)：\(hint)"
        case .transport(let e): return e.localizedDescription
        case .remote(let m): return m
        }
    }
}

/// 统一存储上传接口（SFTP / WebDAV）
protocol StorageClient: AnyObject {
    func testConnection() async throws
    /// 远端文件字节数；不存在返回 `nil`。
    /// 跳过已存在文件时必须比对大小，避免把截断/损坏文件当成成功备份。
    func remoteByteSize(relativePath: String) async throws -> Int64?
    func ensureDirectories(relativeDir: String) async throws
    func uploadFile(
        localURL: URL,
        relativePath: String,
        contentType: String?,
        progress: ((Double) -> Void)?
    ) async throws
    func close() async
}

extension StorageClient {
    func close() async {}

    /// 兼容旧调用：仅判断是否存在（不校验大小）。
    func remoteExists(relativePath: String) async throws -> Bool {
        try await remoteByteSize(relativePath: relativePath) != nil
    }
}

/// 串行化异步操作，避免 SFTP 连接并发写冲突
actor SerialExecutor {
    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        try await work()
    }
}

enum StorageClientFactory {
    static func make(server: StorageServer, credentials: ServerCredentials) throws -> StorageClient {
        let host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw StorageError.invalidConfiguration("主机地址不能为空")
        }
        switch server.protocolKind {
        case .sftp:
            return SFTPStorageClient(server: server, credentials: credentials)
        case .webdav:
            return WebDAVStorageClient(server: server, credentials: credentials)
        }
    }
}
