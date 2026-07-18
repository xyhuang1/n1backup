import Foundation
import Citadel
import Crypto
import NIOCore

/// SFTP 客户端（Citadel 0.12.x）
/// SSH/SFTP 会话在客户端生命周期内复用，操作经 SerialExecutor 串行。
/// 支持：密码登录、OpenSSH 格式私钥（ed25519 / RSA）。
/// 上传按块写；遇断线自动 tearDown + 重连重试，减轻 N1/Dropbear 半死连接问题。
final class SFTPStorageClient: StorageClient, @unchecked Sendable {
    private let server: StorageServer
    private let credentials: ServerCredentials
    private let gate = SerialExecutor()

    private var ssh: SSHClient?
    private var sftp: SFTPClient?
    private var ensuredDirs = Set<String>()

    /// 分块大小：过大占内存且进度粗；过小 SFTP 往返多。256KB 对 N1 局域网较均衡。
    /// 注意：Citadel `SFTPFile.write(_:at:)` 默认 at=0，分块循环必须显式传 offset，
    /// 否则每一块都覆盖写到文件开头，远端文件永远只有最后一块（常见症状：全是 256KB 坏文件）。
    private let chunkSize = 256 * 1024
    private let maxOpRetries = 3

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

    func remoteByteSize(relativePath: String) async throws -> Int64? {
        try await withConnectionRetry {
            try await self.gate.run { [self] in
                let path = normalized(server.joinedRemotePath(relativePath))
                let sftp = try await ensureSFTP()
                do {
                    let attrs = try await sftp.getAttributes(at: path)
                    if let size = attrs.size {
                        return Int64(size)
                    }
                    // 有的服务端不回 size 标志位，但路径存在 → 视为 0 以外的未知存在
                    // 用 -1 表示「存在但未知大小」，调用方应回退为仅按存在跳过
                    return -1
                } catch {
                    // 属性查询失败多数是「不存在」；若像断连则向上抛出以便重连
                    if Self.looksLikeConnectionError(error) {
                        await tearDown()
                        throw StorageError.connectionFailed(friendly(error))
                    }
                    return nil
                }
            }
        }
    }

    func ensureDirectories(relativeDir: String) async throws {
        try await withConnectionRetry {
            try await self.gate.run { [self] in
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
                        if Self.looksLikeConnectionError(error) {
                            await tearDown()
                            throw StorageError.connectionFailed(friendly(error))
                        }
                        // 已存在等
                    }
                    ensuredDirs.insert(built)
                }
                ensuredDirs.insert(full)
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

        let path = normalized(server.joinedRemotePath(relativePath))
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let totalBytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let fileData = try Data(contentsOf: localURL, options: [.mappedIfSafe])
        let size = totalBytes > 0 ? totalBytes : fileData.count
        progress?(0.01)

        try await withConnectionRetry {
            try await self.gate.run { [self] in
                do {
                    let sftp = try await ensureSFTP()
                    try await sftp.withFile(
                        filePath: path,
                        flags: [.write, .create, .truncate]
                    ) { file in
                        if size == 0 {
                            progress?(1)
                            return
                        }
                        // Citadel write 默认 offset=0，不会像本地文件句柄那样自动 seek。
                        // 必须把字节偏移传给 at:，否则每块都从 0 覆盖 → 远端恒为 chunk 大小。
                        var offset = 0
                        let chunk = self.chunkSize
                        while offset < fileData.count {
                            let end = min(offset + chunk, fileData.count)
                            let slice = fileData[offset..<end]
                            var buffer = ByteBufferAllocator().buffer(capacity: slice.count)
                            buffer.writeBytes(slice)
                            try await file.write(buffer, at: UInt64(offset))
                            offset = end
                            let p = Double(offset) / Double(max(fileData.count, 1))
                            progress?(min(max(p, 0.01), 0.99))
                        }
                    }

                    // 上传后校验远端大小，尽早发现截断/覆盖写错误，避免标记为成功
                    if size > 0 {
                        do {
                            let remoteAttrs = try await sftp.getAttributes(at: path)
                            if let remoteSize = remoteAttrs.size, remoteSize != UInt64(size) {
                                throw StorageError.remote(
                                    "远端文件大小不符：期望 \(size) 字节，实际 \(remoteSize) 字节（路径 \(path)）。请重试该文件"
                                )
                            }
                        } catch let e as StorageError {
                            throw e
                        } catch {
                            // 属性查询失败不阻断（部分服务 stat 不稳定），但已尽量校验
                            if Self.looksLikeConnectionError(error) {
                                await tearDown()
                                throw StorageError.connectionFailed(friendly(error))
                            }
                        }
                    }
                    progress?(1)
                } catch let e as StorageError {
                    await tearDown()
                    throw e
                } catch {
                    await tearDown()
                    if Self.looksLikeConnectionError(error) {
                        throw StorageError.connectionFailed(friendly(error))
                    }
                    throw StorageError.remote(friendly(error))
                }
            }
        }
    }

    // MARK: - Retry / connection

    /// 对「像断线」的错误：tearDown 后重试整个操作（最多 maxOpRetries 次）
    private func withConnectionRetry<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxOpRetries {
            do {
                return try await body()
            } catch {
                lastError = error
                let retryable = Self.looksLikeConnectionError(error)
                    || {
                        if case StorageError.connectionFailed = error { return true }
                        return false
                    }()
                guard retryable, attempt + 1 < maxOpRetries else { throw error }
                await gate.run { [self] in await tearDown() }
                // 退避：0.4s / 0.9s
                let ns = UInt64(400_000_000 + attempt * 500_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
        throw lastError ?? StorageError.remote("未知错误")
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
            // N1 / iStoreOS / OpenWrt 上的 Dropbear/OpenSSH 常使用较旧算法
            // （AES-CTR、diffie-hellman-group14、ssh-rsa 主机密钥）。
            // 默认 NIOSSH 算法集协商失败时，iOS 会把 NIOSSHError 显示成
            // 「未能完成操作。NIOSSH.NIOSSHError 错误 1」。
            // SSHAlgorithms.all 追加 AES128CTR + DH-group14 + RSA 主机密钥支持。
            client = try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: auth,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never,
                algorithms: .all,
                connectTimeout: .seconds(30)
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

    /// 判断是否像传输层/会话断开（可重连）
    fileprivate static func looksLikeConnectionError(_ error: Error) -> Bool {
        if case StorageError.connectionFailed = error { return true }
        let ns = error as NSError
        let msg = error.localizedDescription
        let detail = String(describing: error)
        let blob = "\(msg) \(detail) \(ns.domain) \(ns.localizedFailureReason ?? "") \(ns.code)"
            .lowercased()

        if blob.contains("nio core") || blob.contains("niocore") || blob.contains("ioerror") {
            return true
        }
        if blob.contains("niossh") { return true }
        if blob.contains("connection reset")
            || blob.contains("broken pipe")
            || blob.contains("socket")
            || blob.contains("not connected")
            || blob.contains("connection refused")
            || blob.contains("timed out")
            || blob.contains("timeout")
            || blob.contains("eof")
            || blob.contains("channel")
            || blob.contains("closed")
            || blob.contains("reset by peer")
            || blob.contains("network is unreachable")
            || blob.contains("no route to host") {
            return true
        }
        // POSIX ECONNRESET / EPIPE / ETIMEDOUT 等
        if ns.domain == NSPOSIXErrorDomain {
            let c = ns.code
            if [32, 54, 57, 60, 61, 64].contains(c) { return true }
        }
        return false
    }

    private func friendly(_ error: Error) -> String {
        let ns = error as NSError
        let msg = error.localizedDescription
        let detail = String(describing: error)
        let blob = "\(msg) \(detail) \(ns.domain) \(ns.localizedFailureReason ?? "")"
            .lowercased()

        if blob.contains("allauthenticationoptionsfailed")
            || blob.contains("authenticationfailed")
            || blob.contains("unauthorized")
            || blob.contains("invaliduserauthsignature") {
            return "认证失败：请检查用户名/密码，或改用 OpenSSH 私钥（ed25519/RSA）。N1 需允许密码或公钥登录"
        }
        if blob.contains("permission") || blob.contains("denied") {
            return "认证失败或无权限：请检查用户名/密码/私钥，以及目录写权限"
        }
        if blob.contains("timed out") || blob.contains("timeout") {
            return "连接超时：确认 N1 已开启 SSH、端口正确，手机与 N1 在同一 Wi‑Fi"
        }
        if blob.contains("keyexchangenegotiationfailure")
            || blob.contains("algorithm")
            || blob.contains("unsupportedversion") {
            return "SSH 算法协商失败：N1 的 SSH 服务与客户端算法不匹配。请确认使用最新 App（已启用兼容算法）；仍失败时在 N1 检查 dropbear/sshd 配置"
        }
        if blob.contains("connection refused")
            || blob.contains("could not connect")
            || blob.contains("network is unreachable")
            || blob.contains("no route to host")
            || (blob.contains("socket") && blob.contains("not connected")) {
            return "无法连到主机：检查 IP、端口（默认 22）、SSH 是否开启，以及是否在同一局域网"
        }
        // 半死连接 / 并发压垮 Dropbear 常见：NIOCore.IOError 错误 1
        if blob.contains("niocore")
            || blob.contains("nio core")
            || blob.contains("ioerror")
            || blob.contains("io error")
            || (blob.contains("未能完成操作") && blob.contains("错误")) {
            return "连接中断（\(detail)）。常见原因：并发过高压垮 N1 SSH、Wi‑Fi 不稳、会话超时。可在设置把并发降到 2，并重试失败项"
        }
        // iOS 常把 NIOSSHError 显示成「错误 1」，给出可操作提示
        if blob.contains("niossh") || ns.domain.localizedCaseInsensitiveContains("niossh") {
            return "SSH 握手失败（\(detail)）。请确认：1) 主机/端口正确 2) N1 SSH 已开 3) 账号密码可用（FinalShell 能登录）4) 已安装含兼容算法的最新版 App"
        }
        if msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return detail
        }
        return msg
    }
}
