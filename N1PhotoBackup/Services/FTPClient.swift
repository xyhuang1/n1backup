import Foundation

/// 简易 FTP / FTPS 客户端（基于 URLSession）
///
/// 说明：
/// - 适用于基础上传；复杂目录/被动模式细节因系统实现而异
/// - FTPS：打开「使用 TLS」
/// - iStoreOS 若用 vsftpd / proftpd，请开启被动模式并放行端口范围
final class FTPStorageClient: NSObject, StorageClient, URLSessionTaskDelegate {
    private let server: StorageServer
    private let credentials: ServerCredentials

    private lazy var session: URLSession = {
        let conf = URLSessionConfiguration.default
        conf.timeoutIntervalForRequest = 60
        conf.timeoutIntervalForResource = 60 * 60 * 6
        return URLSession(configuration: conf, delegate: self, delegateQueue: nil)
    }()

    private var progressHandlers: [Int: (Double) -> Void] = [:]
    private let progressLock = NSLock()

    init(server: StorageServer, credentials: ServerCredentials) {
        self.server = server
        self.credentials = credentials
        super.init()
    }

    func testConnection() async throws {
        guard let url = makeURL(path: server.normalizedBasePath) else {
            throw StorageError.invalidConfiguration("FTP 地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "LIST"
        applyAuth(to: &request)
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                throw StorageError.authFailed
            }
        } catch let e as StorageError {
            throw e
        } catch {
            // 部分 FTP 对 LIST 返回非 HTTP 风格，只要能握手即可
            // 再尝试上传探测目录
            throw StorageError.connectionFailed(error.localizedDescription)
        }
    }

    func remoteExists(relativePath: String) async throws -> Bool {
        let path = server.joinedRemotePath(relativePath)
        guard let url = makeURL(path: path) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        applyAuth(to: &request)
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200...299).contains(http.statusCode)
            }
            return true
        } catch {
            return false
        }
    }

    func ensureDirectories(relativeDir: String) async throws {
        // URLSession FTP 对 MKD 支持不稳定；上传时由服务端/用户预先建好基础目录更稳妥。
        // 这里尽量按段 MKD。
        let full = server.joinedRemotePath(relativeDir)
        let parts = full.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        var built = ""
        for part in parts {
            built += "/" + part
            guard let url = makeURL(path: built) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "MKD"
            applyAuth(to: &request)
            _ = try? await session.data(for: request)
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
        guard let url = makeURL(path: path) else {
            throw StorageError.invalidConfiguration("FTP 路径无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "STOR"
        applyAuth(to: &request)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = session.uploadTask(with: request, fromFile: localURL) { _, response, error in
                if let error {
                    cont.resume(throwing: StorageError.transport(error))
                    return
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    // FTP 经 URLSession 时状态码可能非标准
                    if http.statusCode == 401 {
                        cont.resume(throwing: StorageError.authFailed)
                        return
                    }
                }
                cont.resume()
            }
            if let progress {
                progressLock.lock()
                progressHandlers[task.taskIdentifier] = progress
                progressLock.unlock()
            }
            task.resume()
        }
    }

    private func makeURL(path: String) -> URL? {
        var components = URLComponents()
        // ftps:// 为隐式 TLS；显式 TLS 系统支持有限，这里 useTLS 时用 ftps
        components.scheme = server.useTLS ? "ftps" : "ftp"
        components.host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = server.port
        if !server.username.isEmpty {
            components.user = server.username
            components.password = credentials.password
        }
        let normalized = path.hasPrefix("/") ? path : "/" + path
        components.path = normalized
        return components.url
    }

    private func applyAuth(to request: inout URLRequest) {
        // userinfo 已在 URL 中；再加 Basic 兼容部分网关
        if !server.username.isEmpty {
            let raw = "\(server.username):\(credentials.password)"
            let token = Data(raw.utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let p = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        progressLock.lock()
        let handler = progressHandlers[task.taskIdentifier]
        progressLock.unlock()
        handler?(min(max(p, 0), 1))
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           server.allowInsecureTLS,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
