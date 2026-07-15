import Foundation
import Photos

enum UploadStatus: Equatable {
    case pending
    case exporting
    case checking
    case uploading(progress: Double)
    case skipped
    case succeeded
    case failed(String)

    var isFinished: Bool {
        switch self {
        case .skipped, .succeeded, .failed: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .pending: return "等待中"
        case .exporting: return "导出中"
        case .checking: return "检查远端"
        case .uploading(let p): return String(format: "上传 %.0f%%", p * 100)
        case .skipped: return "已存在，跳过"
        case .succeeded: return "完成"
        case .failed(let m): return "失败：\(m)"
        }
    }
}

struct UploadItem: Identifiable, Equatable {
    let id: String
    let assetLocalIdentifier: String
    let fileName: String
    let mediaType: PHAssetMediaType
    let creationDate: Date?
    let byteSizeHint: Int64?
    var status: UploadStatus
    var remoteRelativePath: String

    static func == (lhs: UploadItem, rhs: UploadItem) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.remoteRelativePath == rhs.remoteRelativePath
    }
}
