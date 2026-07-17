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

    /// 并发上传路数（每路独立 SFTP 连接）。1–6，默认 3。
    /// N1/Dropbear 并发 SSH 过多易断连（NIOCore.IOError），默认不宜过高。
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
    static let maxConcurrency = 6
    /// 默认 3：在 N1 上比 4 更稳，吞吐通常不差（少断连重试）
    static let defaultConcurrency = 3

    private init() {
        let saved = UserDefaults.standard.object(forKey: Self.concurrencyKey) as? Int
        // 旧默认 4 的用户保留其设置；新安装用 3
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
        let shouldKeepOn = isRunning && keepScreenOn
        UIApplication.shared.isIdleTimerDisabled = shouldKeepOn
    }

    // MARK: - Worker pool

    private func startIfNeeded() {
        guard task == nil else { return }
        isRunning = true
        lastError = nil
        applyIdleTimerPolicy()
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// 持续工作池：N 个 worker 各自独立 SFTP，取完一条立刻取下一条（无批次屏障）。
    /// 建连错开，避免同时握手压垮 Dropbear。
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

        await withTaskGroup(of: Void.self) { group in
            for workerIndex in 0..<concurrency {
                group.addTask { [weak self] in
                    await self?.workerLoop(
                        workerIndex: workerIndex,
                        server: server,
                        credentials: credentials
                    )
                }
            }
        }
    }

    private nonisolated func workerLoop(
        workerIndex: Int,
        server: StorageServer,
        credentials: ServerCredentials
    ) async {
        // 错开建连：0 / 0.5s / 1.0s …
        if workerIndex > 0 {
            try? await Task.sleep(nanoseconds: UInt64(workerIndex) * 500_000_000)
        }
        if Task.isCancelled { return }

        let client: StorageClient
        do {
            client = try StorageClientFactory.make(server: server, credentials: credentials)
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await MainActor.run {
                UploadManager.shared.noteError(msg)
            }
            return
        }
        defer {
            Task { await client.close() }
        }

        let skip = await MainActor.run { UploadManager.shared.skipExisting }

        while !Task.isCancelled {
            guard let item = await MainActor.run(body: { UploadManager.shared.claimNextPending() }) else {
                // 短暂等待，可能有新任务入队或其它 worker 失败回 pending
                try? await Task.sleep(nanoseconds: 200_000_000)
                let stillRunning = await MainActor.run { () -> Bool in
                    let hasPending = UploadManager.shared.items.contains { $0.status == .pending }
                    let hasActive = UploadManager.shared.items.contains {
                        switch $0.status {
                        case .checking, .exporting, .uploading: return true
                        default: return false
                        }
                    }
                    return hasPending || hasActive
                }
                // 若全局已无 pending 且无活跃任务，本 worker 退出
                // 注意：其它 worker 可能仍在 exporting；hasActive 会挡住
                // 仅当完全没有 pending 时退出；active 由各自 worker 自己负责
                let hasPending = await MainActor.run {
                    UploadManager.shared.items.contains { $0.status == .pending }
                }
                if !hasPending {
                    // 再确认没有自己可领的
                    if stillRunning {
                        // 还有人在干活，但没有 pending —— 本 worker 可退出
                        break
                    }
                    break
                }
                continue
            }

            await process(
                item,
                client: client,
                server: server,
                skipExisting: skip
            )
        }
    }

    /// 原子领取下一条 pending，并标为 checking，避免多 worker 抢同一条
    fileprivate func claimNextPending() -> UploadItem? {
        guard let i = items.firstIndex(where: { $0.status == .pending }) else { return nil }
        items[i].status = .checking
        return items[i]
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

    fileprivate func noteError(_ message: String) {
        lastError = message
    }

    private func recomputeFinished() {
        finishedCount = items.filter { $0.status.isFinished }.count
        totalCount = items.count
    }
}
