import Foundation

/// 一条可保存的 SFTP 服务器连接（密码/私钥走 Keychain）
struct StorageServer: Codable, Equatable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var protocolKind: StorageProtocolKind

    var host: String
    var port: Int
    var username: String
    /// 远程备份根路径，如 `/mnt/sda1/PhoneBackup`
    var basePath: String

    /// 是否优先用私钥（私钥正文存 Keychain）
    var usePrivateKey: Bool

    var folderLayout: FolderLayout
    var createdAt: Date
    var updatedAt: Date

    // 旧版多协议字段：解码兼容，新配置不再使用
    var useTLS: Bool
    var allowInsecureTLS: Bool
    var shareName: String
    var domain: String
    var workgroup: String
    var ftpPassive: Bool

    enum FolderLayout: String, Codable, CaseIterable, Identifiable {
        case yearMonth
        case flat

        var id: String { rawValue }

        var title: String {
            switch self {
            case .yearMonth: return "按年/月 (2026/07)"
            case .flat: return "全部放同一目录"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, protocolKind, host, port, username, basePath
        case usePrivateKey, folderLayout, createdAt, updatedAt
        case useTLS, allowInsecureTLS, shareName, domain, workgroup, ftpPassive
    }

    init(
        id: UUID,
        name: String,
        protocolKind: StorageProtocolKind = .sftp,
        host: String,
        port: Int,
        username: String,
        basePath: String,
        usePrivateKey: Bool = false,
        folderLayout: FolderLayout = .yearMonth,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        useTLS: Bool = false,
        allowInsecureTLS: Bool = true,
        shareName: String = "",
        domain: String = "",
        workgroup: String = "WORKGROUP",
        ftpPassive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.protocolKind = .sftp
        self.host = host
        self.port = port
        self.username = username
        self.basePath = basePath
        self.usePrivateKey = usePrivateKey
        self.folderLayout = folderLayout
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.useTLS = useTLS
        self.allowInsecureTLS = allowInsecureTLS
        self.shareName = shareName
        self.domain = domain
        self.workgroup = workgroup
        self.ftpPassive = ftpPassive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        // 旧版若存了 webdav/smb/ftp，统一按 SFTP 读；用户需改端口/路径
        protocolKind = .sftp
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        basePath = try c.decodeIfPresent(String.self, forKey: .basePath) ?? "/PhoneBackup"
        usePrivateKey = try c.decodeIfPresent(Bool.self, forKey: .usePrivateKey) ?? false
        folderLayout = try c.decodeIfPresent(FolderLayout.self, forKey: .folderLayout) ?? .yearMonth
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        useTLS = try c.decodeIfPresent(Bool.self, forKey: .useTLS) ?? false
        allowInsecureTLS = try c.decodeIfPresent(Bool.self, forKey: .allowInsecureTLS) ?? true
        shareName = try c.decodeIfPresent(String.self, forKey: .shareName) ?? ""
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
        workgroup = try c.decodeIfPresent(String.self, forKey: .workgroup) ?? "WORKGROUP"
        ftpPassive = try c.decodeIfPresent(Bool.self, forKey: .ftpPassive) ?? true
        if port <= 0 { port = 22 }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(StorageProtocolKind.sftp, forKey: .protocolKind)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(basePath, forKey: .basePath)
        try c.encode(usePrivateKey, forKey: .usePrivateKey)
        try c.encode(folderLayout, forKey: .folderLayout)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    static func blank(protocol kind: StorageProtocolKind = .sftp) -> StorageServer {
        StorageServer(
            id: UUID(),
            name: "",
            protocolKind: .sftp,
            host: "",
            port: 22,
            username: "",
            basePath: "/mnt/sda1/PhoneBackup",
            usePrivateKey: false,
            folderLayout: .yearMonth
        )
    }

    var displayTitle: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        if host.isEmpty { return "未命名 SFTP" }
        return "SFTP · \(host)"
    }

    var summaryLine: String {
        var parts: [String] = ["SFTP"]
        if !host.isEmpty { parts.append("\(host):\(port)") }
        if !basePath.isEmpty { parts.append(basePath) }
        return parts.joined(separator: "  ")
    }

    var normalizedBasePath: String {
        var p = basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { p = "/" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    mutating func touch() {
        updatedAt = Date()
        protocolKind = .sftp
    }

    func joinedRemotePath(_ relative: String) -> String {
        let rel = relative
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        let base = normalizedBasePath
        if base == "/" {
            return rel.isEmpty ? "/" : "/" + rel
        }
        return rel.isEmpty ? base : base + "/" + rel
    }
}

struct ServerCredentials: Equatable {
    var password: String
    var privateKey: String
    var passphrase: String

    static let empty = ServerCredentials(password: "", privateKey: "", passphrase: "")
}
