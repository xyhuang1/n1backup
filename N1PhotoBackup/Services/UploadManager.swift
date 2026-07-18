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
    /// 近几秒完成速度（张/秒，含成功+跳过）
    @Published private(set) var itemsPerSecond: Double = 0
    /// 用于 UI：`2.3 张/s` 或 `—`
    @Published private(set) var speedText: String = "—"

    /// 并发上传路数（每路独立连接）。1–6，默认 3。
    /// SFTP 在 N1/Dropbear 上并发过高易断连且总吞吐常下降；运行时会再把 SFTP 封顶到 3。
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

    /// SFTP 实际并发上限（即使用户滑到 6，N1 Dropbear 也按此封顶）
    static let sftpEffectiveMaxConcurrency = 3

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

    /// 完成时间戳滑动窗口，用于计算张/秒
    private var completionTimestamps: [CFAbsoluteTime] = []
    private let speedWindowSeconds: CFAbsoluteTime = 8
    private var lastSpeedUIUpdate: CFAbsoluteTime = 0

    private static let concurrencyKey = "upload_max_concurrent_v1"
    private static let keepScreenKey = "upload_keep_screen_on_v1"
    static let minConcurrency = 1
    static let maxConcurrency = 6
    /// 默认 3：SFTP 在 N1 上更稳；WebDAV 可在设置里调高
    static let defaultConcurrency = 3

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
        completionTimestamps.removeAll()
        itemsPerSecond = 0
        speedText = "—"
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
        // 新一轮任务：重置速度窗口，避免旧数据干扰
        completionTimestamps.removeAll()
        itemsPerSecond = 0
        speedText = "—"
        applyIdleTimerPolicy()
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// 持续工作池：N 个 worker 各自独立连接，取完一条立刻取下一条（无批次屏障）。
    /// SFTP 建连错开，避免同时握手压垮 Dropbear；WebDAV 几乎无握手成本。
    private func runLoop() async {
        defer {
            isRunning = false
            task = nil
            applyIdleTimerPolicy()
            // 结束后保留最后一次速度约 2 秒可读，随后清零
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !self.isRunning else { return }
                self.itemsPerSecond = 0
                self.speedText = "—"
            }
        }

        guard let server = ServerStore.shared.selectedServer else {
            lastError = "未选择服务器"
            return
        }
        let credentials = ServerStore.shared.credentials(for: server)
        var concurrency = Self.clampConcurrency(maxConcurrentUploads)
        // SFTP：6 路常压垮 Dropbear，总吞吐更差；实际 worker 数封顶
        if server.protocolKind == .sftp {
            concurrency = min(concurrency, Self.sftpEffectiveMaxConcurrency)
        }
        // SFTP 需要错开建连；WebDAV 可并行立刻开
        let staggerNs: UInt64 = server.protocolKind == .sftp ? 350_000_000 : 50_000_000

        await withTaskGroup(of: Void.self) { group in
            for workerIndex in 0..<concurrency {
                group.addTask { [weak self] in
                    await self?.workerLoop(
                        workerIndex: workerIndex,
                        server: server,
                        credentials: credentials,
                        staggerNs: staggerNs
                    )
                }
            }
        }
    }

    private nonisolated func workerLoop(
        workerIndex: Int,
        server: StorageServer,
        credentials: ServerCredentials,
        staggerNs: UInt64
    ) async {
        // 错开建连：0 / stagger / 2*stagger …
        if workerIndex > 0 {
            try? await Task.sleep(nanoseconds: UInt64(workerIndex) * staggerNs)
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
            // 路径先按入队时信息确定（creationDate 已在 enqueue 写入），避免为了 skip 检查先整文件导出。
            var remotePath = item.remoteRelativePath

            // 1) 快速路径：只看远端是否存在（不比对 size）。
            //    完整正确的文件会被跳过；历史上 256KB 截断坏文件用户通常已手动清理。
            //    若仍有坏文件残留，关掉「跳过已存在」或删掉远端后重传即可。
            if skipExisting {
                await MainActor.run { UploadManager.shared.update(itemId: itemId, status: .checking) }
                if try await client.remoteExists(relativePath: remotePath) {
                    await MainActor.run { UploadManager.shared.update(itemId: itemId, status: .skipped) }
                    return
                }
            }

            // 2) 导出原图/原视频（耗时；放在 skip 之后。ExportGate 最多 2 路同时导出）
            await MainActor.run { UploadManager.shared.update(itemId: itemId, status: .exporting) }

            let asset = PhotoLibraryService.fetchAssets(localIdentifiers: [item.assetLocalIdentifier]).first
            guard let asset else {
                await MainActor.run { UploadManager.shared.update(itemId: itemId, status: .failed("资源已删除")) }
                return
            }

            let exported = try await ExportGate.shared.withPermit {
                try await PhotoLibraryService.exportOriginal(asset: asset)
            }
            defer { try? FileManager.default.removeItem(at: exported.fileURL) }

            let refined = DatePath.remoteRelativePath(
                fileName: item.fileName,
                date: exported.creationDate ?? item.creationDate,
                layout: server.folderLayout
            )
            if refined != remotePath {
                remotePath = refined
                await MainActor.run { UploadManager.shared.updatePath(itemId: itemId, path: remotePath) }
                // 路径变了再查一次，避免重复上传
                if skipExisting, try await client.remoteExists(relativePath: remotePath) {
                    await MainActor.run { UploadManager.shared.update(itemId: itemId, status: .skipped) }
                    return
                }
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
        let wasFinished = items[i].status.isFinished
        items[i].status = status
        if status.isFinished {
            lastProgressAt.removeValue(forKey: itemId)
            // 成功/跳过计入吞吐；失败不算速度
            if !wasFinished {
                switch status {
                case .succeeded, .skipped:
                    recordCompletion()
                default:
                    break
                }
            }
        }
        recomputeFinished()
    }

    private func recordCompletion() {
        let now = CFAbsoluteTimeGetCurrent()
        completionTimestamps.append(now)
        pruneAndPublishSpeed(now: now, force: true)
    }

    private func pruneAndPublishSpeed(now: CFAbsoluteTime, force: Bool) {
        let cutoff = now - speedWindowSeconds
        completionTimestamps.removeAll { $0 < cutoff }
        if !force, now - lastSpeedUIUpdate < 0.4 { return }
        lastSpeedUIUpdate = now

        guard let first = completionTimestamps.first, completionTimestamps.count >= 1 else {
            itemsPerSecond = 0
            if !isRunning { speedText = "—" }
            return
        }
        // 窗口内样本不足时用已过去的实际时长
        let elapsed = max(now - first, 0.5)
        let rate = Double(completionTimestamps.count) / elapsed
        itemsPerSecond = rate
        if rate >= 10 {
            speedText = String(format: "%.0f 张/s", rate)
        } else if rate >= 1 {
            speedText = String(format: "%.1f 张/s", rate)
        } else if rate > 0 {
            // 慢速时显示 张/分钟 更直观，同时保留 张/s
            let perMin = rate * 60
            if perMin >= 1 {
                speedText = String(format: "%.1f 张/s (≈%.0f/分)", rate, perMin)
            } else {
                speedText = String(format: "%.2f 张/s", rate)
            }
        } else {
            speedText = "—"
        }
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
        // 运行中定期刷新速度窗口（即使暂时无完成项也衰减）
        if isRunning {
            pruneAndPublishSpeed(now: CFAbsoluteTimeGetCurrent(), force: false)
        }
    }
}
