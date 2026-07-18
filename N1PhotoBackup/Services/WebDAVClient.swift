import Foundation

/// WebDAV 实现（URLSession，无第三方依赖）
/// 适合 AList / Nextcloud / Nginx WebDAV；局域网常比多路 SFTP 更稳、更省 N1 CPU。
final class WebDAVStorageClient: NSObject, StorageClient, URLSessionTaskDelegate, URLSessionDelegate {
    private let server: StorageServer
    private let credentials: ServerCredentials

    private lazy var session: URLSession = {
        let conf = URLSessionConfiguration.default
        conf.timeoutIntervalForRequest = 60
        conf.timeoutIntervalForResource = 60 * 60 * 6
        conf.waitsForConnectivity = true
        // 与 UploadManager 并发路数匹配，允许多路 PUT
        conf.httpMaximumConnectionsPerHost = 8
        conf.httpShouldUsePipelining = false
        return URLSession(configuration: conf, delegate: self, delegateQueue: nil)
    }()

    private var progressHandlers: [Int: (Double) -> Void] = [:]
    private let progressLock = NSLock()
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

    /// 连通性探测：路径不存在时尝试自动建目录；部分服务对 PROPFIND 返回 405 时改用 OPTIONS/HEAD。
    func testConnection() async throws {
        let base = server.normalizedBasePath

        // 1) PROPFIND 目标路径（最标准）
        do {
            _ = try await propfind(absolutePath: base, depth: 0)
            return
        } catch let StorageError.httpStatus(code, _) where code == 404 {
            // 路径尚不存在 → 逐级 MKCOL 后复测
            try await ensureAbsoluteDirectories(base)
            do {
                _ = try await propfind(absolutePath: base, depth: 0)
                return
            } catch {
                // 有的服务建完目录后 PROPFIND 仍 405，继续兜底
            }
        } catch StorageError.authFailed {
            throw StorageError.authFailed
        } catch let StorageError.httpStatus(code, _) where code == 405 || code == 501 {
            // 服务不支持 PROPFIND，走 OPTIONS/HEAD
        } catch {
            // 其它错误留给后续 OPTIONS/HEAD 再确认是否「服务可达但方法受限」
            // 若服务完全不可达，OPTIONS 也会同样失败
            if case StorageError.transport = error { throw error }
            if case StorageError.invalidConfiguration = error { throw error }
        }

        // 2) OPTIONS 探测服务是否可达 / 是否声明 WebDAV
        if try await optionsReachable(absolutePath: base) { return }

        // 3) HEAD / GET 兜底（部分反向代理禁 OPTIONS/PROPFIND）
        if try await headOrGetReachable(absolutePath: base) { return }

        // 4) 根可达但目标路径不通：尝试自动建目录后再测
        // 注意：不能把 await 写进 `||` 短路表达式（Swift 会报 not support concurrency）
        if base != "/" {
            let rootOK: Bool
            if (try? await optionsReachable(absolutePath: "/")) == true {
                rootOK = true
            } else if (try? await headOrGetReachable(absolutePath: "/")) == true {
                rootOK = true
            } else {
                rootOK = false
            }
            if rootOK {
                do {
                    try await ensureAbsoluteDirectories(base)
                    if try await optionsReachable(absolutePath: base) { return }
                    if try await headOrGetReachable(absolutePath: base) { return }
                    // MKCOL 未抛错：目录已建或已存在，上传阶段还会 ensureDirectories
                    return
                } catch {
                    // 继续落到最终错误，附带建目录失败原因
                    if let le = error as? LocalizedError, let d = le.errorDescription {
                        throw StorageError.remote("WebDAV 路径不可用：\(d)")
                    }
                    throw error
                }
            }
        }

        throw StorageError.remote(
            "WebDAV 探测失败。请检查：1) 主机/端口 2) 基础路径（AList 常含 /dav/...）3) 账号密码 4) HTTP/HTTPS 是否选对"
        )
    }

    func remoteByteSize(relativePath: String) async throws -> Int64? {
        let path = server.joinedRemotePath(relativePath)
        guard let url = makeURL(path: path) else { throw StorageError.invalidConfiguration("URL 无效") }

        // 1) HEAD Content-Length
        let head = authorizedRequest(url: url, method: "HEAD")
        do {
            let (_, response) = try await data(for: head, allowStatuses: [200, 204, 301, 302, 404, 405, 501])
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 404 { return nil }
                if (200...299).contains(http.statusCode) {
                    let len = http.value(forHTTPHeaderField: "Content-Length")
                        .flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
                    return len ?? -1
                }
            }
        } catch {
            // fallthrough
        }

        // 2) PROPFIND getcontentlength
        do {
            let xml = try await propfind(absolutePath: path, depth: 0)
            let lower = xml.lowercased()
            let exists = lower.contains("200 ok") || lower.contains("<d:href") || lower.contains("<d:multistatus")
            guard exists else { return nil }
            if let size = Self.parseContentLength(from: xml) {
                return size
            }
            return -1
        } catch let StorageError.httpStatus(code, _) where code == 404 {
            return nil
        } catch let StorageError.httpStatus(code, _) where code == 405 || code == 501 {
            // 无法列举时保守当作不存在，上传会覆盖/创建
            return nil
        }
    }

    /// 从 PROPFIND XML 里抠 getcontentlength
    private static func parseContentLength(from xml: String) -> Int64? {
        // 兼容 <d:getcontentlength>123</d:getcontentlength> / <lp1:getcontentlength>…
        let pattern = #"(?i)<[^>]*getcontentlength[^>]*>\s*(\d+)\s*</[^>]*getcontentlength>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        guard let match = regex.firstMatch(in: xml, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return Int64(xml[r])
    }

    func ensureDirectories(relativeDir: String) async throws {
        let full = server.joinedRemotePath(relativeDir)
        try await ensureAbsoluteDirectories(full)
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

    private func ensureAbsoluteDirectories(_ full: String) async throws {
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

    private func mkcol(absolutePath: String) async throws {
        guard let url = makeURL(path: absolutePath) else { throw StorageError.invalidConfiguration("URL 无效") }
        let request = authorizedRequest(url: url, method: "MKCOL")
        // 201 新建成功；200/301/302 已存在或重定向；405 方法不允许但资源常已存在；409 父目录不存在
        let (_, response) = try await data(for: request, allowStatuses: [200, 201, 301, 302, 403, 405, 409])
        guard let http = response as? HTTPURLResponse else { return }
        if [201, 405, 200, 301, 302].contains(http.statusCode) { return }
        if http.statusCode == 409 {
            // 父级可能刚建好但尚未可见，或路径已是文件；再 PROPFIND 看是否已存在
            if await pathLooksPresent(absolutePath) { return }
            throw StorageError.remote("创建目录失败（父目录不存在）: \(absolutePath)")
        }
        if http.statusCode == 403 {
            if await pathLooksPresent(absolutePath) { return }
            throw StorageError.remote("无权限创建目录: \(absolutePath)")
        }
        throw StorageError.httpStatus(http.statusCode, nil)
    }

    private func pathLooksPresent(_ absolutePath: String) async -> Bool {
        do {
            _ = try await propfind(absolutePath: absolutePath, depth: 0)
            return true
        } catch {
            return (try? await headOrGetReachable(absolutePath: absolutePath)) == true
        }
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

        let (data, response) = try await data(for: request, allowStatuses: [200, 207, 404, 401, 403, 405, 501])
        guard let http = response as? HTTPURLResponse else { throw StorageError.remote("无响应") }
        if http.statusCode == 401 || http.statusCode == 403 { throw StorageError.authFailed }
        if http.statusCode == 404 { throw StorageError.httpStatus(404, nil) }
        if http.statusCode == 405 || http.statusCode == 501 {
            throw StorageError.httpStatus(http.statusCode, String(data: data, encoding: .utf8))
        }
        if ![200, 207].contains(http.statusCode) {
            throw StorageError.httpStatus(http.statusCode, String(data: data, encoding: .utf8))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func optionsReachable(absolutePath: String) async throws -> Bool {
        guard let url = makeURL(path: absolutePath) else { throw StorageError.invalidConfiguration("URL 无效") }
        let request = authorizedRequest(url: url, method: "OPTIONS")
        do {
            let (_, response) = try await data(for: request, allowStatuses: [200, 204, 401, 403, 404, 405])
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 401 || http.statusCode == 403 { throw StorageError.authFailed }
            if http.statusCode == 404 { return false }
            // 任意 2xx/405 都说明 HTTP 服务可达；若声明 DAV 更佳
            if let dav = http.value(forHTTPHeaderField: "DAV"), !dav.isEmpty { return true }
            if let allow = http.value(forHTTPHeaderField: "Allow")?.uppercased(),
               allow.contains("PUT") || allow.contains("MKCOL") || allow.contains("PROPFIND") {
                return true
            }
            return (200...299).contains(http.statusCode) || http.statusCode == 405
        } catch StorageError.authFailed {
            throw StorageError.authFailed
        } catch {
            return false
        }
    }

    private func headOrGetReachable(absolutePath: String) async throws -> Bool {
        guard let url = makeURL(path: absolutePath) else { throw StorageError.invalidConfiguration("URL 无效") }

        let head = authorizedRequest(url: url, method: "HEAD")
        do {
            let (_, response) = try await data(for: head, allowStatuses: [200, 204, 301, 302, 401, 403, 404, 405, 501])
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 { throw StorageError.authFailed }
                if (200...299).contains(http.statusCode) || http.statusCode == 301 || http.statusCode == 302 {
                    return true
                }
            }
        } catch StorageError.authFailed {
            throw StorageError.authFailed
        } catch {
            // fallthrough to GET
        }

        // 部分服务禁 HEAD，用轻量 GET
        var get = authorizedRequest(url: url, method: "GET")
        get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (_, response) = try await data(for: get, allowStatuses: [200, 206, 301, 302, 401, 403, 404, 405, 416])
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 { throw StorageError.authFailed }
                if http.statusCode == 404 { return false }
                return (200...299).contains(http.statusCode)
                    || http.statusCode == 301 || http.statusCode == 302
                    || http.statusCode == 416
            }
        } catch StorageError.authFailed {
            throw StorageError.authFailed
        } catch {
            return false
        }
        return false
    }

    // MARK: - HTTP

    private func makeURL(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = server.useTLS ? "https" : "http"
        components.host = Self.sanitizeHost(server.host)
        let port = server.port > 0 ? server.port : (server.useTLS ? 443 : 80)
        components.port = port
        let normalized = path.hasPrefix("/") ? path : "/" + path
        // 分段编码，保留 /；中文与空格等会被 percent-encode
        components.percentEncodedPath = normalized
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { seg -> String in
                if seg.isEmpty { return "" }
                // urlPathAllowed 过宽，显式排除保留字以免路径段被拆坏
                var allowed = CharacterSet.urlPathAllowed
                allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
                return seg.addingPercentEncoding(withAllowedCharacters: allowed) ?? String(seg)
            }
            .joined(separator: "/")
        return components.url
    }

    /// 去掉用户误填的 scheme / 路径 / 空白
    static func sanitizeHost(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("https://") {
            h = String(h.dropFirst("https://".count))
        } else if h.hasPrefix("http://") {
            h = String(h.dropFirst("http://".count))
        }
        if let slash = h.firstIndex(of: "/") {
            h = String(h[..<slash])
        }
        if let at = h.firstIndex(of: "@") {
            h = String(h[h.index(after: at)...])
        }
        // host:port 时只留 host（端口用独立字段）
        if h.contains(":"), !h.contains("]"), let colon = h.lastIndex(of: ":"),
           h[h.index(after: colon)...].allSatisfy(\.isNumber) {
            h = String(h[..<colon])
        }
        return h.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func authorizedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !server.username.isEmpty {
            let raw = "\(server.username):\(credentials.password)"
            let token = Data(raw.utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        // 部分 AList/反向代理对缺 User-Agent 不友好
        request.setValue("N1PhotoBackup/1.7", forHTTPHeaderField: "User-Agent")
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
