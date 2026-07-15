import Foundation
import Photos
import Combine

@MainActor
final class UploadManager: ObservableObject {
    static let shared = UploadManager()

    @Published private(set) var items: [UploadItem] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published var skipExisting: Bool = true
    @Published private(set) var finishedCount: Int = 0
    @Published private(set) var totalCount: Int = 0

    private var task: Task<Void, Never>?
    private let maxConcurrent = 2

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
        let newItems: [UploadItem] = assets.map { asset in
            let name = PhotoLibraryService.preferredFileName(for: asset)
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
        items.append(contentsOf: newItems)
        totalCount = items.count
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
        totalCount = items.count
        recomputeFinished()
    }

    func clearAll() {
        task?.cancel()
        task = nil
        isRunning = false
        items.removeAll()
        totalCount = 0
        finishedCount = 0
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

    // MARK: - Worker

    private func startIfNeeded() {
        guard task == nil else { return }
        isRunning = true
        lastError = nil
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        defer {
            isRunning = false
            task = nil
        }

        while !Task.isCancelled {
            let pending = items.filter { $0.status == .pending }
            if pending.isEmpty { break }

            let batch = Array(pending.prefix(maxConcurrent))
            for item in batch {
                update(itemId: item.id, status: .exporting)
            }

            await withTaskGroup(of: Void.self) { group in
                for item in batch {
                    let snapshot = item
                    group.addTask { [weak self] in
                        await self?.processOffMain(snapshot)
                    }
                }
            }
            recomputeFinished()
        }
    }

    private nonisolated func processOffMain(_ item: UploadItem) async {
        let itemId = item.id

        let context: (StorageServer, ServerCredentials, Bool)? = await MainActor.run {
            guard let server = ServerStore.shared.selectedServer else { return nil }
            let creds = ServerStore.shared.credentials(for: server)
            return (server, creds, UploadManager.shared.skipExisting)
        }

        guard let (server, credentials, skip) = context else {
            await MainActor.run {
                UploadManager.shared.markFailed(itemId: itemId, message: "未选择服务器")
            }
            return
        }

        let client: StorageClient
        do {
            client = try StorageClientFactory.make(server: server, credentials: credentials)
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await MainActor.run { UploadManager.shared.markFailed(itemId: itemId, message: msg) }
            return
        }

        do {
            if skip {
                await MainActor.run { UploadManager.shared.update(itemId: itemId, status: .checking) }
                if try await client.remoteExists(relativePath: item.remoteRelativePath) {
                    await MainActor.run { UploadManager.shared.update(itemId: itemId, status: .skipped) }
                    return
                }
            }

            await MainActor.run { UploadManager.shared.update(itemId: itemId, status: .exporting) }

            let asset: PHAsset? = await MainActor.run {
                PhotoLibraryService.fetchAssets(localIdentifiers: [item.assetLocalIdentifier]).first
            }
            guard let asset else {
                await MainActor.run { UploadManager.shared.update(itemId: itemId, status: .failed("资源已删除")) }
                return
            }

            let exported = try await PhotoLibraryService.exportOriginal(asset: asset)
            defer { try? FileManager.default.removeItem(at: exported.fileURL) }

            let remotePath = DatePath.remoteRelativePath(
                fileName: exported.fileName,
                date: exported.creationDate ?? item.creationDate,
                layout: server.folderLayout
            )
            await MainActor.run { UploadManager.shared.updatePath(itemId: itemId, path: remotePath) }

            if skip, try await client.remoteExists(relativePath: remotePath) {
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
                    UploadManager.shared.update(itemId: itemId, status: .uploading(progress: p))
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
        recomputeFinished()
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
