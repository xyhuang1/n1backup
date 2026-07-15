import Foundation

#if canImport(AMSMB2)
import AMSMB2
#endif

/// SMB / Samba 客户端
///
/// 完整功能依赖 SPM 包：https://github.com/amosavian/AMSMB2
/// Xcode → 项目 → Package Dependencies → 添加上述 URL，产品勾选 AMSMB2
final class SMBStorageClient: StorageClient {
    private let server: StorageServer
    private let credentials: ServerCredentials

    init(server: StorageServer, credentials: ServerCredentials) {
        self.server = server
        self.credentials = credentials
    }

    func testConnection() async throws {
        #if canImport(AMSMB2)
        let manager = try makeManager()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            manager.connectShare(name: server.normalizedShareName) { error in
                if let error {
                    cont.resume(throwing: StorageError.connectionFailed(error.localizedDescription))
                } else {
                    manager.disconnectShare()
                    cont.resume()
                }
            }
        }
        #else
        throw StorageError.notAvailable(Self.dependencyHint)
        #endif
    }

    func remoteExists(relativePath: String) async throws -> Bool {
        #if canImport(AMSMB2)
        let path = server.joinedRemotePath(relativePath)
        let manager = try makeManager()
        return try await withCheckedThrowingContinuation { cont in
            manager.connectShare(name: server.normalizedShareName) { error in
                if let error {
                    cont.resume(throwing: StorageError.connectionFailed(error.localizedDescription))
                    return
                }
                manager.attributesOfItem(atPath: path) { _, error in
                    manager.disconnectShare()
                    if let error = error as NSError? {
                        // 找不到文件
                        if error.domain == NSPOSIXErrorDomain && error.code == ENOENT {
                            cont.resume(returning: false)
                        } else if "\(error)".lowercased().contains("not found") {
                            cont.resume(returning: false)
                        } else {
                            cont.resume(returning: false)
                        }
                    } else {
                        cont.resume(returning: true)
                    }
                }
            }
        }
        #else
        throw StorageError.notAvailable(Self.dependencyHint)
        #endif
    }

    func ensureDirectories(relativeDir: String) async throws {
        #if canImport(AMSMB2)
        let full = server.joinedRemotePath(relativeDir)
        let parts = full.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        let manager = try makeManager()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            manager.connectShare(name: server.normalizedShareName) { error in
                if let error {
                    cont.resume(throwing: StorageError.connectionFailed(error.localizedDescription))
                    return
                }
                var built = ""
                func createNext(_ index: Int) {
                    if index >= parts.count {
                        manager.disconnectShare()
                        cont.resume()
                        return
                    }
                    built = built.isEmpty ? parts[index] : built + "/" + parts[index]
                    manager.createDirectory(atPath: built) { error in
                        // 已存在忽略
                        _ = error
                        createNext(index + 1)
                    }
                }
                createNext(0)
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
        #if canImport(AMSMB2)
        let parent = (relativePath as NSString).deletingLastPathComponent
        if !parent.isEmpty && parent != "." {
            try await ensureDirectories(relativeDir: parent)
        }
        let path = server.joinedRemotePath(relativePath)
        let data = try Data(contentsOf: localURL)
        let total = Double(data.count)
        let manager = try makeManager()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            manager.connectShare(name: server.normalizedShareName) { error in
                if let error {
                    cont.resume(throwing: StorageError.connectionFailed(error.localizedDescription))
                    return
                }
                manager.write(data: data, progress: { bytes in
                    if total > 0 { progress?(Double(bytes) / total) }
                    return true
                }, toPath: path) { error in
                    manager.disconnectShare()
                    if let error {
                        cont.resume(throwing: StorageError.remote(error.localizedDescription))
                    } else {
                        progress?(1)
                        cont.resume()
                    }
                }
            }
        }
        #else
        throw StorageError.notAvailable(Self.dependencyHint)
        #endif
    }

    #if canImport(AMSMB2)
    private func makeManager() throws -> SMB2Manager {
        guard !server.normalizedShareName.isEmpty else {
            throw StorageError.invalidConfiguration("SMB 共享名不能为空")
        }
        let host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "smb://\(host)") else {
            throw StorageError.invalidConfiguration("SMB 主机无效")
        }
        let credential = URLCredential(
            user: composedUsername(),
            password: credentials.password,
            persistence: .forSession
        )
        guard let manager = SMB2Manager(url: url, credential: credential) else {
            throw StorageError.connectionFailed("无法创建 SMB 连接")
        }
        return manager
    }

    private func composedUsername() -> String {
        let user = server.username
        let domain = server.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if domain.isEmpty { return user }
        // DOMAIN\user 形式
        if user.contains("\\") { return user }
        return "\(domain)\\\(user)"
    }
    #endif

    static let dependencyHint = """
    SMB 需要添加 Swift 包 AMSMB2：
    Xcode → Project → Package Dependencies
    URL: https://github.com/amosavian/AMSMB2
    然后重新编译。
    """
}
