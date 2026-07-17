import Foundation
import Photos
import Combine
import UIKit

@MainActor
final class UploadManager: ObservableObject {
    static let shared = UploadManager()

    @Published private(set) var items: [UploadItem] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published var skipExisting: Bool = true
    @Published private(set) var finishedCount: Int = 0
    @Published private(set) var totalCount: Int = 0

    /// 并发上传路数（每路独立 SFTP 连接）。1–8，默认 4。
    @Published var maxConcurrentUploads: Int {
        didSet {
            let clamped = Self.clampConcurrency(maxConcurrentUploads)
            if clamped != maxConcurrentUploads {
                maxConcurrentUploads = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.concurrencyKey)
        }
    }

    /// 备份运行时保持屏幕常亮（默认开）
    @Published var keepScreenOn: Bool {
        didSet {
            UserDefaults.standard.set(keepScreenOn, forKey: Self.keepScreenKey)
            applyIdleTimerPolicy()
        }
    }

    private var task: Task<Void, Never>?
    /// 进度 UI 节流：避免每个 TCP 分片都触发 SwiftUI 刷新
    private var lastProgressAt: [String: CFAbsoluteTime] = [:]
    private let progressMinInterval: CFAbsoluteTime = 0.2

    private static let concurrencyKey = "upload_max_concurrent_v1"
    private static let keepScreenKey = "upload_keep_screen_on_v1"
    static let minConcurrency = 1
    static let maxConcurrency = 8
    static let defaultConcurrency = 4

    private init() {
        let saved = UserDefaults.standard.object(forKey: Self.concurrencyKey) as? Int
        maxConcurrentUploads = Self.clampConcurrency(saved ?? Self.defaultConcurrency)
        if UserDefaults.standard.object(forKey: Self.keepScreenKey) == nil {
            keepScreenOn = true
        } else {
            keepScreenOn = UserDefaults.standard.bool(forKey: Self.keepScreenKey)
        }
    }

    static func clampConcurrency(_ value: Int) -> Int {
        min(max(value, minConcurrency), maxConcurrency)
    }

    var progressText: String {
        guard totalCount > 0 else { return "空闲" }
        return "\(finishedCount)/\(totalCount)"
    }

    var overallProgress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(finishedCount) / Double(totalCount)
    }

    // MARK: - Enqueue

    func enqueue(assets: [PHAsset], server: StorageServer) {
        // 队列中已有（未失败）的同资源不再重复入队
        let activeIds = Set(
            items.compactMap { item -> String? in
                if case .failed = item.status { return nil }
                return item.assetLocalIdentifier
            }
        )

        let newItems: [UploadItem] = assets.compactMap { asset in
            guard !activeIds.contains(asset.localIdentifier) else { return nil }
            let name = PhotoLibraryService.uniqueFileName(for: asset)
            let remote = DatePath.remoteRelativePath(
                fileName: name,
                date: asset.creationDate,
                layout: server.folderLayout
            )
            return UploadItem(
                id: UUID().uuidString,
                assetLocalIdentifier: asset.localIdentifier,
                fileName: name,
                mediaType: asset.mediaType,
                creationDate: asset.creationDate,
                byteSizeHint: nil,
                status: .pending,
                remoteRelativePath: remote
            )
        }
        guard !newItems.isEmpty else { return }
        items.append(contentsOf: newItems)
        recomputeFinished()
        startIfNeeded()
    }

    func enqueueRecent(days: Int) async throws {
        try await PhotoLibraryService.ensureAuthorized()
        guard let server = ServerStore.shared.selectedServer else {
            throw StorageError.invalidConfiguration("请先在「服务器」里添加并选择一台存储")
        }
        let result = PhotoLibraryService.fetchAssets(days: days)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        enqueue(assets: list, server: server)
    }

    func enqueueAll() async throws {
        try await enqueueRecent(days: 0)
    }

    func enqueueIdentifiers(_ ids: [String]) async throws {
        try await PhotoLibraryService.ensureAuthorized()
        guard let server = ServerStore.shared.selectedServer else {
            throw StorageError.invalidConfiguration("请先在「服务器」里添加并选择一台存储")
        }
        let assets = PhotoLibraryService.fetchAssets(localIdentifiers: ids)
        enqueue(assets: assets, server: server)
    }

    func clearFinished() {
        items.removeAll { $0.status.isFinished }
        lastProgressAt = lastProgressAt.filter { id, _ in items.contains(where: { $0.id == id }) }
        recomputeFinished()
    }

    func clearAll() {
        task?.cancel()
        task = nil
        isRunning = false
        items.removeAll()
        lastProgressAt.removeAll()
        totalCount = 0
        finishedCount = 0
        applyIdleTimerPolicy()
    }

    func retryFailed() {
        for i in items.indices {
            if case .failed = items[i].status {
                items[i].status = .pending
            }
        }
        recomputeFinished()
        startIfNeeded()
    }

    // MARK: - Idle timer (screen awake)

    private func applyIdleTimerPolicy() {
        // 仅在「上传中且开启常亮」时禁用休眠
        let shouldKeepOn = isRunning && keepScreenOn
        UIApplication.shared.isIdleTimerDisabled = shouldKeepOn
    }

    // MARK: - Worker

    private func startIfNeeded() {
        guard task == nil else { return }
        isRunning = true
        lastError = nil
        applyIdleTimerPolicy()
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        defer {
            isRunning = false
            task = nil
            applyIdleTimerPolicy()
        }

        guard let server = ServerStore.shared.selectedServer else {
            lastError = "未选择服务器"
            return
        }
        let credentials = ServerStore.shared.credentials(for: server)
        let concurrency = Self.clampConcurrency(maxConcurrentUploads)

        // 每路并发使用独立 SFTP 连接：单连接内仍串行，多连接才能真正提速
        var clients: [StorageClient] = []
        clients.reserveCapacity(concurrency)
        do {
            for _ in 0..<concurrency {
                clients.append(try StorageClientFactory.make(server: server, credentials: credentials))
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = msg
            for i in items.indices where items[i].status == .pending {
                items[i].status = .failed(msg)
            }
            recomputeFinished()
            return
        }

        await withTaskCancellationHandler {
            let skip = skipExisting
            while !Task.isCancelled {
                let pending = items.filter { $0.status == .pending }
                if pending.isEmpty { break }

                let batch = Array(pending.prefix(clients.count))
                await withTaskGroup(of: Void.self) { group in
                    for (index, item) in batch.enumerated() {
                        let snapshot = item
                        let client = clients[index]
                        group.addTask { [weak self] in
                            await self?.process(
                                snapshot,
                                client: client,
                                server: server,
                                skipExisting: skip
                            )
                        }
                    }
                }
                recomputeFinished()
            }
        } onCancel: {
            // 取消时尽快释放连接（close 幂等）
            Task {
                for c in clients {
                    await c.close()
                }
            }
        }

        for c in clients {
            await c.close()
        }
    }

    private nonisolated func process(
        _ item: UploadItem,
        client: StorageClient,
        server: StorageServer,
        skipExisting: Bool
    ) async {
        let itemId = item.id

        do {
            if skipExisting {
                await MainActor.run { UploadManager.shared.update(itemId: itemId, status: .checking) }
                if try await client.remoteExists(relativePath: item.remoteRelativePath) {
                    await MainActor.run { UploadManager.shared.update(itemId: itemId, status: .skipped) }
                    return
                }
            }

            await MainActor.run { UploadManager.shared.update(itemId: itemId, status: .exporting) }

            let asset = PhotoLibraryService.fetchAssets(localIdentifiers: [item.assetLocalIdentifier]).first
            guard let asset else {
                await MainActor.run { UploadManager.shared.update(itemId: itemId, status: .failed("资源已删除")) }
                return
            }

            let exported = try await PhotoLibraryService.exportOriginal(asset: asset)
            defer { try? FileManager.default.removeItem(at: exported.fileURL) }

            // 导出后的真实文件名可能与预估不同；保持入队时的 unique 名，仅在远程路径日期上对齐
            let remotePath = DatePath.remoteRelativePath(
                fileName: item.fileName,
                date: exported.creationDate ?? item.creationDate,
                layout: server.folderLayout
            )
            if remotePath != item.remoteRelativePath {
                await MainActor.run { UploadManager.shared.updatePath(itemId: itemId, path: remotePath) }
            }

            if skipExisting, try await client.remoteExists(relativePath: remotePath) {
                await MainActor.run { UploadManager.shared.update(itemId: itemId, status: .skipped) }
                return
            }

            await MainActor.run { UploadManager.shared.update(itemId: itemId, status: .uploading(progress: 0)) }

            try await client.uploadFile(
                localURL: exported.fileURL,
                relativePath: remotePath,
                contentType: exported.contentType
            ) { p in
                Task { @MainActor in
                    UploadManager.shared.updateProgress(itemId: itemId, progress: p)
                }
            }

            await MainActor.run { UploadManager.shared.update(itemId: itemId, status: .succeeded) }
        } catch is CancellationError {
            await MainActor.run { UploadManager.shared.update(itemId: itemId, status: .pending) }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await MainActor.run { UploadManager.shared.markFailed(itemId: itemId, message: msg) }
        }
    }

    fileprivate func update(itemId: String, status: UploadStatus) {
        guard let i = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[i].status = status
        if status.isFinished {
            lastProgressAt.removeValue(forKey: itemId)
        }
        recomputeFinished()
    }

    fileprivate func updateProgress(itemId: String, progress: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastProgressAt[itemId],
           now - last < progressMinInterval,
           progress < 0.99 {
            return
        }
        lastProgressAt[itemId] = now
        guard let i = items.firstIndex(where: { $0.id == itemId }) else { return }
        // 仅在仍处于上传态时更新，避免覆盖终态
        if case .uploading = items[i].status {
            items[i].status = .uploading(progress: min(max(progress, 0), 1))
        } else if case .pending = items[i].status {
            items[i].status = .uploading(progress: min(max(progress, 0), 1))
        } else if case .exporting = items[i].status {
            items[i].status = .uploading(progress: min(max(progress, 0), 1))
        } else if case .checking = items[i].status {
            items[i].status = .uploading(progress: min(max(progress, 0), 1))
        }
    }

    fileprivate func updatePath(itemId: String, path: String) {
        guard let i = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[i].remoteRelativePath = path
    }

    fileprivate func markFailed(itemId: String, message: String) {
        update(itemId: itemId, status: .failed(message))
        lastError = message
    }

    private func recomputeFinished() {
        finishedCount = items.filter { $0.status.isFinished }.count
        totalCount = items.count
    }
}
