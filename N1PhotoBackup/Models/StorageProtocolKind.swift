import Foundation

/// 支持的存储协议
enum StorageProtocolKind: String, Codable, CaseIterable, Identifiable {
    case webdav
    case smb
    case sftp
    case ftp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .webdav: return "WebDAV"
        case .smb: return "SMB / Samba"
        case .sftp: return "SFTP"
        case .ftp: return "FTP / FTPS"
        }
    }

    var subtitle: String {
        switch self {
        case .webdav: return "Alist、Nextcloud、通用 WebDAV"
        case .smb: return "iStoreOS Samba 网络共享"
        case .sftp: return "SSH 文件传输（OpenSSH）"
        case .ftp: return "传统 FTP / 显式 FTPS"
        }
    }

    var systemImage: String {
        switch self {
        case .webdav: return "globe"
        case .smb: return "externaldrive.connected.to.line.below"
        case .sftp: return "terminal"
        case .ftp: return "arrow.up.arrow.down.circle"
        }
    }

    var defaultPort: Int {
        switch self {
        case .webdav: return 5244
        case .smb: return 445
        case .sftp: return 22
        case .ftp: return 21
        }
    }

    /// 该协议在表单中展示的字段
    var formFields: Set<ServerFormField> {
        switch self {
        case .webdav:
            return [.name, .host, .port, .useTLS, .allowInsecureTLS, .username, .password, .basePath, .folderLayout]
        case .smb:
            return [.name, .host, .port, .username, .password, .shareName, .basePath, .folderLayout, .domain, .workgroup]
        case .sftp:
            return [.name, .host, .port, .username, .password, .privateKey, .basePath, .folderLayout]
        case .ftp:
            return [.name, .host, .port, .useTLS, .allowInsecureTLS, .username, .password, .basePath, .folderLayout, .ftpPassive]
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
    case shareName
    case domain
    case workgroup
    case folderLayout
    case ftpPassive
}
