import Foundation

/// WebDAV 实现（URLSession，无第三方依赖）
final class WebDAVStorageClient: NSObject, StorageClient, URLSessionTaskDelegate, URLSessionDelegate {
    private let server: StorageServer
    private let credentials: ServerCredentials

    private lazy var session: URLSession = {
        let conf = URLSessionConfiguration.default
        conf.timeoutIntervalForRequest = 60
        conf.timeoutIntervalForResource = 60 * 60 * 6
        conf.waitsForConnectivity = true
        conf.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: conf, delegate: self, delegateQueue: nil)
    }()

    private var progressHandlers: [Int: (Double) -> Void] = [:]
    private let progressLock = NSLock()
    /// 本轮上传已创建过的远程目录，避免重复 MKCOL
    private var ensuredDirs = Set<String>()
    private let dirLock = NSLock()

    init(server: StorageServer, credentials: ServerCredentials) {
        self.server = server
        self.credentials = credentials
        super.init()
    }

    deinit {
        session.invalidateAndCancel()
    }

    func close() async {
        session.finishTasksAndInvalidate()
    }

    func testConnection() async throws {
        _ = try await propfind(absolutePath: server.normalizedBasePath, depth: 0)
    }

    func remoteExists(relativePath: String) async throws -> Bool {
        let path = server.joinedRemotePath(relativePath)
        guard let url = makeURL(path: path) else { throw StorageError.invalidConfiguration("URL 无效") }

        let head = authorizedRequest(url: url, method: "HEAD")
        do {
            let (_, response) = try await data(for: head, allowStatuses: [200, 204, 404, 405])
            if let http = response as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) { return true }
                if http.statusCode == 404 { return false }
            }
        } catch {
            // fallthrough to PROPFIND
        }

        do {
            let xml = try await propfind(absolutePath: path, depth: 0)
            let lower = xml.lowercased()
            return lower.contains("200 ok") || lower.contains("<d:href") || lower.contains("<d:multistatus")
        } catch let StorageError.httpStatus(code, _) where code == 404 {
            return false
        }
    }

    func ensureDirectories(relativeDir: String) async throws {
        let full = server.joinedRemotePath(relativeDir)
        dirLock.lock()
        let already = ensuredDirs.contains(full)
        dirLock.unlock()
        if already { return }

        let parts = full.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        var built = ""
        for part in parts {
            built += "/" + part
            dirLock.lock()
            let known = ensuredDirs.contains(built)
            dirLock.unlock()
            if known { continue }
            try await mkcol(absolutePath: built)
            dirLock.lock()
            ensuredDirs.insert(built)
            dirLock.unlock()
        }
        dirLock.lock()
        ensuredDirs.insert(full)
        dirLock.unlock()
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
        guard let url = makeURL(path: path) else { throw StorageError.invalidConfiguration("URL 无效") }

        var request = authorizedRequest(url: url, method: "PUT")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let fileSize = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if fileSize > 0 {
            request.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")
        }
        try await upload(request: request, fromFile: localURL, progress: progress)
    }

    // MARK: - WebDAV

    private func mkcol(absolutePath: String) async throws {
        guard let url = makeURL(path: absolutePath) else { throw StorageError.invalidConfiguration("URL 无效") }
        let request = authorizedRequest(url: url, method: "MKCOL")
        let (_, response) = try await data(for: request, allowStatuses: [200, 201, 301, 302, 405, 409])
        guard let http = response as? HTTPURLResponse else { return }
        // 201 新建；405 已存在；200/3xx 部分网关
        if [201, 405, 200, 301, 302].contains(http.statusCode) { return }
        if http.statusCode == 409 { throw StorageError.remote("创建目录失败（父目录不存在）: \(absolutePath)") }
        throw StorageError.httpStatus(http.statusCode, nil)
    }

    private func propfind(absolutePath: String, depth: Int) async throws -> String {
        guard let url = makeURL(path: absolutePath) else { throw StorageError.invalidConfiguration("URL 无效") }
        var request = authorizedRequest(url: url, method: "PROPFIND")
        request.setValue(String(depth), forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8" ?>
        <d:propfind xmlns:d="DAV:">
          <d:prop><d:resourcetype/><d:getcontentlength/></d:prop>
        </d:propfind>
        """.utf8)

        let (data, response) = try await data(for: request, allowStatuses: [200, 207, 404, 401, 403])
        guard let http = response as? HTTPURLResponse else { throw StorageError.remote("无响应") }
        if http.statusCode == 401 || http.statusCode == 403 { throw StorageError.authFailed }
        if http.statusCode == 404 { throw StorageError.httpStatus(404, nil) }
        if ![200, 207].contains(http.statusCode) {
            throw StorageError.httpStatus(http.statusCode, String(data: data, encoding: .utf8))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - HTTP

    private func makeURL(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = server.useTLS ? "https" : "http"
        components.host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = server.port
        let normalized = path.hasPrefix("/") ? path : "/" + path
        // 对路径段做编码，保留 /
        components.percentEncodedPath = normalized
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { seg -> String in
                if seg.isEmpty { return "" }
                return seg.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(seg)
            }
            .joined(separator: "/")
        return components.url
    }

    private func authorizedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !server.username.isEmpty {
            let raw = "\(server.username):\(credentials.password)"
            let token = Data(raw.utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func data(for request: URLRequest, allowStatuses: Set<Int>) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !allowStatuses.contains(http.statusCode) {
                if http.statusCode == 401 { throw StorageError.authFailed }
                throw StorageError.httpStatus(http.statusCode, String(data: data, encoding: .utf8))
            }
            return (data, response)
        } catch let e as StorageError {
            throw e
        } catch {
            throw StorageError.transport(error)
        }
    }

    private func upload(request: URLRequest, fromFile: URL, progress: ((Double) -> Void)?) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = session.uploadTask(with: request, fromFile: fromFile) { data, response, error in
                if let error {
                    cont.resume(throwing: StorageError.transport(error))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    cont.resume(throwing: StorageError.remote("无响应"))
                    return
                }
                if (200...299).contains(http.statusCode) {
                    cont.resume()
                } else if http.statusCode == 401 {
                    cont.resume(throwing: StorageError.authFailed)
                } else {
                    let text = data.flatMap { String(data: $0, encoding: .utf8) }
                    cont.resume(throwing: StorageError.httpStatus(http.statusCode, text))
                }
            }
            if let progress {
                progressLock.lock()
                progressHandlers[task.taskIdentifier] = progress
                progressLock.unlock()
            }
            task.resume()
        }
    }

    // MARK: - URLSession delegates

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

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        progressLock.lock()
        progressHandlers[task.taskIdentifier] = nil
        progressLock.unlock()
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
