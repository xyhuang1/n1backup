import Foundation

/// 一条可保存的存储服务器连接配置（不含密码明文，密码走 Keychain）
struct StorageServer: Codable, Equatable, Identifiable, Hashable {
    var id: UUID
    /// 用户自定义显示名，如「家里 N1」「备份盘」
    var name: String
    var protocolKind: StorageProtocolKind

    var host: String
    var port: Int
    /// WebDAV / FTP：是否 HTTPS / FTPS
    var useTLS: Bool
    /// 忽略自签证书（仅 TLS）
    var allowInsecureTLS: Bool

    var username: String
    /// 远程备份根路径。WebDAV/SFTP/FTP: `/PhoneBackup`；SMB: 共享内相对路径如 `PhoneBackup` 或 `/Photos`
    var basePath: String

    /// SMB 共享名，如 `sda1` / `photos`（不含 \\host\）
    var shareName: String
    /// SMB 域名 / AD（可空）
    var domain: String
    /// SMB 工作组（可空，默认 WORKGROUP）
    var workgroup: String

    /// SFTP：是否优先用私钥（私钥正文存 Keychain）
    var usePrivateKey: Bool

    /// FTP 被动模式
    var ftpPassive: Bool

    var folderLayout: FolderLayout

    /// 创建时间
    var createdAt: Date
    var updatedAt: Date

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

    static func blank(protocol kind: StorageProtocolKind = .webdav) -> StorageServer {
        StorageServer(
            id: UUID(),
            name: "",
            protocolKind: kind,
            host: "",
            port: kind.defaultPort,
            useTLS: false,
            allowInsecureTLS: true,
            username: "",
            basePath: kind == .smb ? "PhoneBackup" : "/PhoneBackup",
            shareName: "",
            domain: "",
            workgroup: "WORKGROUP",
            usePrivateKey: false,
            ftpPassive: true,
            folderLayout: .yearMonth,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    var displayTitle: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        if host.isEmpty { return "未命名服务器" }
        return "\(protocolKind.title) · \(host)"
    }

    var summaryLine: String {
        var parts: [String] = [protocolKind.title]
        if !host.isEmpty {
            parts.append("\(host):\(port)")
        }
        switch protocolKind {
        case .smb:
            if !shareName.isEmpty { parts.append("共享:\(shareName)") }
        default:
            if !basePath.isEmpty { parts.append(basePath) }
        }
        return parts.joined(separator: "  ")
    }

    /// 规范化路径：去掉首尾多余空格；非 SMB 保证以 / 开头
    var normalizedBasePath: String {
        var p = basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if protocolKind == .smb {
            while p.hasPrefix("/") { p.removeFirst() }
            while p.hasSuffix("/") { p.removeLast() }
            return p
        }
        if p.isEmpty { p = "/" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    var normalizedShareName: String {
        shareName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
    }

    mutating func touch() {
        updatedAt = Date()
    }

    /// 合并相对路径到 basePath 下
    func joinedRemotePath(_ relative: String) -> String {
        let rel = relative
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
            .joined(separator: "/")

        switch protocolKind {
        case .smb:
            let base = normalizedBasePath
            if base.isEmpty { return rel }
            return rel.isEmpty ? base : base + "/" + rel
        default:
            let base = normalizedBasePath
            if base == "/" {
                return rel.isEmpty ? "/" : "/" + rel
            }
            return rel.isEmpty ? base : base + "/" + rel
        }
    }
}

// MARK: - 凭据（不进 Codable 主结构，单独 Keychain）

struct ServerCredentials: Equatable {
    var password: String
    /// PEM / OpenSSH 私钥全文（SFTP 可选）
    var privateKey: String
    var passphrase: String

    static let empty = ServerCredentials(password: "", privateKey: "", passphrase: "")
}
