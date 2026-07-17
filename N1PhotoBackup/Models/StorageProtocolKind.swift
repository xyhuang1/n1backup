import Foundation

/// 仅支持 SFTP（本应用唯一上传协议）
enum StorageProtocolKind: String, Codable, CaseIterable, Identifiable {
    case sftp

    var id: String { rawValue }

    var title: String { "SFTP" }

    var subtitle: String { "SSH 文件传输（OpenSSH / dropbear）" }

    var systemImage: String { "terminal" }

    var defaultPort: Int { 22 }

    var formFields: Set<ServerFormField> {
        [.name, .host, .port, .username, .password, .privateKey, .basePath, .folderLayout]
    }
}

enum ServerFormField: Hashable {
    case name
    case host
    case port
    case username
    case password
    case privateKey
    case basePath
    case folderLayout
}
