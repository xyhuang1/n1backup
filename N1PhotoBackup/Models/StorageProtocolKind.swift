import Foundation

/// 支持的存储协议：SFTP + WebDAV
enum StorageProtocolKind: String, Codable, CaseIterable, Identifiable {
    case sftp
    case webdav

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sftp: return "SFTP"
        case .webdav: return "WebDAV"
        }
    }

    var subtitle: String {
        switch self {
        case .sftp: return "SSH 文件传输（OpenSSH / Dropbear）"
        case .webdav: return "AList / Nextcloud / 通用 WebDAV（局域网常更快更稳）"
        }
    }

    var systemImage: String {
        switch self {
        case .sftp: return "terminal"
        case .webdav: return "globe"
        }
    }

    var defaultPort: Int {
        switch self {
        case .sftp: return 22
        case .webdav: return 5244 // AList 常见端口
        }
    }

    var defaultBasePath: String {
        switch self {
        case .sftp: return "/mnt/sda1/PhoneBackup"
        case .webdav: return "/dav/本地存储/PhoneBackup"
        }
    }

    var formFields: Set<ServerFormField> {
        switch self {
        case .sftp:
            return [.name, .host, .port, .username, .password, .privateKey, .basePath, .folderLayout]
        case .webdav:
            return [.name, .host, .port, .useTLS, .allowInsecureTLS, .username, .password, .basePath, .folderLayout]
        }
    }
}

enum ServerFormField: Hashable {
    case name
    case host
    case port
    case useTLS
    case allowInsecureTLS
    case username
    case password
    case privateKey
    case basePath
    case folderLayout
}
