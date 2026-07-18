import Foundation
import Photos
import UniformTypeIdentifiers

enum PhotoLibraryError: LocalizedError {
    case denied
    case limitedExportFailed
    case exportFailed(String)
    case resourceMissing

    var errorDescription: String? {
        switch self {
        case .denied:
            return "没有相册权限，请到 设置 → N1相册备份 中开启"
        case .limitedExportFailed:
            return "受限相册权限下导出失败"
        case .exportFailed(let m):
            return "导出失败：\(m)"
        case .resourceMissing:
            return "找不到相册资源"
        }
    }
}

struct ExportedAsset {
    let fileURL: URL
    let fileName: String
    let contentType: String?
    let creationDate: Date?
}

/// 限制同时从相册导出的路数，避免多 worker 把 Photos I/O 打满导致更慢。
/// 许可在 acquire/release 间传递：有等待者时 release 直接唤醒，不先减 running。
actor ExportGate {
    static let shared = ExportGate()
    private let maxConcurrent = 2
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 持有许可执行 body，结束后自动释放（含抛错路径）。
    func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
        // resume 时已继承 release 让出的槽位，running 不变
    }

    private func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
            return
        }
        running = max(0, running - 1)
    }
}

enum PhotoLibraryService {
    static func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                cont.resume(returning: status)
            }
        }
    }

    static func ensureAuthorized() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let newStatus = await requestAuthorization()
            if newStatus != .authorized && newStatus != .limited {
                throw PhotoLibraryError.denied
            }
        default:
            throw PhotoLibraryError.denied
        }
    }

    /// 获取最近 N 天的资源
    static func fetchAssets(days: Int?) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = false
        options.wantsIncrementalChangeDetails = false

        if let days, days > 0 {
            let from = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date.distantPast
            options.predicate = NSPredicate(
                format: "(mediaType == %d OR mediaType == %d) AND creationDate >= %@",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue,
                from as NSDate
            )
        } else {
            options.predicate = NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )
        }
        return PHAsset.fetchAssets(with: options)
    }

    static func fetchAssets(localIdentifiers: [String]) -> [PHAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            list.append(asset)
        }
        return list
    }

    static func preferredFileName(for asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        if let primary = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto || $0.type == .video || $0.type == .fullSizeVideo })
            ?? resources.first {
            let name = primary.originalFilename
            if !name.isEmpty { return sanitizeFileName(name) }
        }
        let ext: String
        switch asset.mediaType {
        case .video: ext = "mov"
        case .image: ext = "heic"
        default: ext = "bin"
        }
        let stamp = (asset.creationDate ?? Date()).timeIntervalSince1970
        return sanitizeFileName(String(format: "IMG_%.0f.%@", stamp, ext))
    }

    /// 远端文件名：在原文件名上附加 localIdentifier 短哈希，避免同秒连拍 / 同名覆盖
    static func uniqueFileName(for asset: PHAsset) -> String {
        let base = preferredFileName(for: asset)
        let ns = base as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        let tag = shortTag(from: asset.localIdentifier)
        if ext.isEmpty {
            return sanitizeFileName("\(stem)_\(tag)")
        }
        return sanitizeFileName("\(stem)_\(tag).\(ext)")
    }

    private static func shortTag(from localIdentifier: String) -> String {
        // PHAsset.localIdentifier 形如 "A1B2…/L0/001"，取稳定短后缀即可
        let compact = localIdentifier
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "-", with: "")
        if compact.count <= 8 { return compact }
        return String(compact.prefix(8))
    }

    static func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }

    /// 导出原图/原视频到临时目录
    static func exportOriginal(asset: PHAsset) async throws -> ExportedAsset {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = pickBestResource(from: resources, mediaType: asset.mediaType) else {
            throw PhotoLibraryError.resourceMissing
        }

        let fileName = sanitizeFileName(
            resource.originalFilename.isEmpty ? preferredFileName(for: asset) : resource.originalFilename
        )
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("n1_export", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dest = tempDir.appendingPathComponent("\(UUID().uuidString)_\(fileName)")

        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }

        try await writeResource(resource, to: dest)

        let uti = resource.uniformTypeIdentifier
        let contentType = UTType(uti)?.preferredMIMEType
            ?? mimeType(forExtension: (fileName as NSString).pathExtension)

        return ExportedAsset(
            fileURL: dest,
            fileName: fileName,
            contentType: contentType,
            creationDate: asset.creationDate
        )
    }

    private static func pickBestResource(from resources: [PHAssetResource], mediaType: PHAssetMediaType) -> PHAssetResource? {
        switch mediaType {
        case .video:
            return resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first(where: { $0.type == .video })
                ?? resources.first
        case .image:
            return resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo })
                ?? resources.first
        default:
            return resources.first
        }
    }

    private static func writeResource(_ resource: PHAssetResource, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error {
                    cont.resume(throwing: PhotoLibraryError.exportFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            }
        }
    }

    private static func mimeType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic", "heif": return "image/heic"
        case "gif": return "image/gif"
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        case "m4v": return "video/x-m4v"
        case "dng": return "image/x-adobe-dng"
        default: return "application/octet-stream"
        }
    }
}
